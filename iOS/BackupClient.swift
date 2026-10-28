import Foundation
import Observation
import Photos
import ImagoKit
import UIKit
import BackgroundTasks
import Network
import os

/// Shows in Console.app (select the iPhone, filter on subsystem `com.example.photobackup.ios`).
let log = Logger(subsystem: "com.example.photobackup.ios", category: "backup")

/// Pairs with a Mac, finds it on the network, compares libraries and uploads what the Mac is missing.
@MainActor @Observable
final class BackupClient {
    enum Phase: Equatable {
        case idle
        case searching
        case connecting
        case comparing
        /// `done`/`total` count photos and videos in the whole library, not just this session's files.
        case uploading(done: Int, total: Int, current: String)
        /// The connection dropped; trying again in `seconds`.
        case waitingToRetry(attempt: Int, seconds: Int, reason: String)
        case finished(sent: Int, failed: Int)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .searching, .connecting, .comparing, .uploading, .waitingToRetry: true
            default: false
            }
        }
    }

    /// Where an unfinished backup stopped, kept across launches so it can resume.
    struct Progress: Codable, Equatable {
        var done: Int
        var total: Int
    }

    enum ClientError: LocalizedError {
        case notPaired, noPhotosAccess, unexpectedReply, refused(String), pairingRejected

        var errorDescription: String? {
            switch self {
            case .notPaired: "Pair with your Mac first."
            case .noPhotosAccess: "Imago needs access to your photos. Turn it on in Settings › Privacy › Photos."
            case .unexpectedReply: "Your Mac sent something unexpected. Make sure both apps are up to date."
            case .refused(let reason): reason
            case .pairingRejected: "Your Mac didn't accept the code. Open Add iPhone on the Mac and scan again."
            }
        }
    }

    private(set) var phase: Phase = .idle {
        didSet { reportToSystem() }
    }
    /// Non-nil while a backup has started but not finished. Reopening the app resumes it.
    private(set) var unfinished: Progress? {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(unfinished), forKey: "unfinishedBackup") }
    }
    /// The iOS 26 continued-processing task running this backup, if any (a `BGContinuedProcessingTask`).
    private var systemTask: AnyObject?
    /// True from the moment `run` starts until it returns, whichever way it was started.
    private var isRunInProgress = false
    /// The task doing the current run, so a new start can stop a run that can't keep going.
    private var activeRun: Task<Void, Never>?
    /// True while a user-started backup waits for iOS to start its continued-processing task.
    private var isStarting = false
    /// How far through the current step (scanning the library, or the current file) the backup is, 0...1.
    /// iOS marks a continued-processing task stalled, and may stop it, if its progress stops moving.
    private var stepFraction: Double = 0
    private var stepFractionChanged = Date.distantPast
    /// Files this session uploads, and how many it has finished, for the system progress.
    private var sessionFileCount = 0
    private var sessionFilesDone = 0
    /// What the system progress last showed, out of `systemUnits`. It only ever goes up: iOS treats
    /// a task whose progress doesn't move, or jumps back on a reconnect, as stalled.
    private var reportedUnits: Int64 = 0
    /// When the system progress last went up.
    private var lastReport = Date.distantPast
    private var lastProgressLog = Date.distantPast
    private static let systemUnits: Int64 = 1_000_000
    /// The library scan from this run's first attempt. Reconnecting doesn't rescan, which takes a minute on a big library.
    private var runManifest: [ManifestEntry]?
    private(set) var credential: DeviceCredential?
    private(set) var isPairing = false
    private(set) var photoCount = 0
    private(set) var videoCount = 0
    /// What photos and videos take up, and the iPhone's free space. Kept across launches so the page
    /// shows the last numbers at once while new ones are measured.
    private(set) var storage: Storage? {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(storage), forKey: "storage") }
    }
    private var measuring: Task<Void, Never>?

    struct Storage: Codable, Equatable {
        var photoBytes: Int64
        var videoBytes: Int64
        var freeBytes: Int64
        var totalBytes: Int64

        /// Apps, the system and everything else.
        var otherBytes: Int64 { max(totalBytes - freeBytes - photoBytes - videoBytes, 0) }
    }
    private(set) var lastBackup: Date? {
        didSet { UserDefaults.standard.set(lastBackup, forKey: "lastBackup") }
    }
    private(set) var lastAutomaticRun: Date? {
        didSet { UserDefaults.standard.set(lastAutomaticRun, forKey: "lastAutomaticRun") }
    }
    var deviceName: String {
        didSet { UserDefaults.standard.set(deviceName, forKey: "deviceName") }
    }
    var overnightBackup: Bool {
        didSet {
            UserDefaults.standard.set(overnightBackup, forKey: "overnightBackup")
            if overnightBackup { BackgroundBackup.schedule() } else { BackgroundBackup.cancel() }
        }
    }

    /// Changes the Mac asked for, waiting for the user to review them here.
    private(set) var macChanges: [LibraryChange] = [] {
        didSet { saveChangeState() }
    }
    private(set) var isApplyingChanges = false
    /// Favorites and album changes from the Mac are made as soon as they arrive while the app is open,
    /// and deletions go straight to iOS's confirmation. Off: every change waits for a review here.
    var applyRightAway: Bool {
        didSet {
            UserDefaults.standard.set(applyRightAway, forKey: "applyRightAway")
            scheduleAutoApply()
        }
    }
    /// Set while the live link is connected, to send reports to the Mac the moment there are any.
    var sendReportsNow: (([ChangeReport]) -> Void)?
    /// Set while the live link is connected (version 7): asks the Mac for the files of a put-back
    /// the user approved. They arrive over the link (see `LiveLink`).
    var requestRestoreNow: ((LibraryChange) -> Void)?
    /// Put-backs approved and on their way from the Mac.
    private(set) var restoringIDs: Set<UUID> = []
    /// A put-back was approved while the Mac couldn't be reached: it waits for the connection.
    private(set) var restoreNeedsConnection = false
    private var autoApply: Task<Void, Never>?
    /// What the user did with earlier changes; sent to the Mac at the next backup.
    private var unsentReports: [ChangeReport] = [] {
        didSet { saveChangeState() }
    }
    /// Recently handled changes, so one isn't shown again before the Mac hears about it.
    private var handledChangeIDs: [UUID] = [] {
        didSet { saveChangeState() }
    }

    private static let credentialAccount = "device-credential"
    private static let deviceIDAccount = "device-id"
    private static let manifestBatchSize = 500
    // Deadlines for network waits. Past these the connection is treated as dead and the backup reconnects.
    // Local work (exporting from Photos, hashing) isn't covered, so a slow iCloud download never trips them.
    nonisolated private static let connectTimeout: TimeInterval = 30
    nonisolated private static let sendTimeout: TimeInterval = 60
    nonisolated private static let replyTimeout: TimeInterval = 120
    /// After the last chunk the Mac re-hashes the whole file; a large video on a slow drive takes a while.
    nonisolated private static let verifyTimeout: TimeInterval = 300
    /// Connection drops are retried this many times, waiting 4, 8, 16, 32, then 60 seconds.
    private static let maxRetries = 8
    /// When the Mac isn't on the network at all (e.g. the phone is away from home), give up after
    /// this many searches instead of retrying for minutes. The backup resumes when the app next opens.
    private static let maxSearches = 3
    /// Set by `retryNow()` to cut the current wait short.
    private var retryRequested = false

    init() {
        if let data = Keychain.load(account: Self.credentialAccount) {
            credential = try? JSONDecoder().decode(DeviceCredential.self, from: data)
        }
        lastBackup = UserDefaults.standard.object(forKey: "lastBackup") as? Date
        lastAutomaticRun = UserDefaults.standard.object(forKey: "lastAutomaticRun") as? Date
        deviceName = UserDefaults.standard.string(forKey: "deviceName") ?? Self.systemDeviceName
        overnightBackup = UserDefaults.standard.object(forKey: "overnightBackup") as? Bool ?? true
        applyRightAway = UserDefaults.standard.object(forKey: "applyRightAway") as? Bool ?? true
        storage = UserDefaults.standard.data(forKey: "storage").flatMap { try? JSONDecoder().decode(Storage.self, from: $0) }
        if let data = UserDefaults.standard.data(forKey: "unfinishedBackup") {
            unfinished = try? JSONDecoder().decode(Progress.self, from: data)
        }
        loadChangeState()
    }

    /// The name set in Settings › General › About ("Jia's iPhone"). iOS only reveals it to apps that hold
    /// Apple's user-assigned-device-name entitlement; otherwise it returns the model, "iPhone".
    static var systemDeviceName: String { UIDevice.current.name }

    /// True when we only know the model name, so the user should type a better one.
    var hasGenericName: Bool {
        let name = deviceName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == UIDevice.current.model
    }

    // MARK: Library

    func refreshCounts() async {
        // Free space shows even before Imago may read the library.
        defer { measureStorage() }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
                || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else { return }
        photoCount = PHAsset.fetchAssets(with: .image, options: nil).count
        videoCount = PHAsset.fetchAssets(with: .video, options: nil).count
    }

    /// Free space now, then the library's size in the background. A measure already running is left to finish.
    private func measureStorage() {
        let disk = Self.diskSpace()
        if let disk, var known = storage {
            known.freeBytes = disk.free
            known.totalBytes = disk.total
            storage = known
        }
        guard measuring == nil else { return }
        measuring = Task {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            let readable = status == .authorized || status == .limited
            let sizes = await Task.detached(priority: .utility) { readable ? PhotoLibrary.sizes() : (photos: 0, videos: 0) }.value
            let disk = Self.diskSpace() ?? disk
            storage = Storage(photoBytes: sizes.photos, videoBytes: sizes.videos,
                              freeBytes: disk?.free ?? 0, totalBytes: disk?.total ?? 0)
            measuring = nil
        }
    }

    /// The space Settings shows as available, which counts what iOS can clear on its own.
    private static func diskSpace() -> (free: Int64, total: Int64)? {
        let values = try? URL(filePath: NSHomeDirectory()).resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])
        guard let free = values?.volumeAvailableCapacityForImportantUsage, let total = values?.volumeTotalCapacity else { return nil }
        return (free, Int64(total))
    }

    // MARK: Pairing

    /// Connects to the Mac's pairing service with the scanned one-time code and receives this phone's own key.
    func pair(with code: PairingInfo) async throws {
        isPairing = true
        defer { isPairing = false }
        let endpoint = try await BackupService.findServer(id: code.serverID, mode: .pair)
        let peer = PeerConnection(endpoint: endpoint, parameters: BackupService.parameters(
            secret: code.secret, identity: BackupService.pairingIdentity
        ))
        defer { peer.cancel() }
        do {
            try await peer.start()
        } catch {
            throw ClientError.pairingRejected
        }
        try await peer.send(.control(.pairRequest(
            deviceID: Self.deviceID, deviceName: deviceName, protocolVersion: ProtocolVersion.current
        )))
        var replies = peer.frames.makeAsyncIterator()
        guard case .control(.paired(let key, let serverName))? = try await replies.next() else {
            throw ClientError.unexpectedReply
        }
        let credential = DeviceCredential(serverID: code.serverID, serverName: serverName, deviceID: Self.deviceID, key: key)
        try Keychain.save(try JSONEncoder().encode(credential), account: Self.credentialAccount)
        if self.credential?.serverID != credential.serverID {
            lastBackup = nil
            lastAutomaticRun = nil
            unfinished = nil
        }
        self.credential = credential
        phase = .idle
        if overnightBackup { BackgroundBackup.schedule() }
    }

    func unpair() {
        Keychain.delete(account: Self.credentialAccount)
        credential = nil
        unfinished = nil
        phase = .idle
        BackgroundBackup.cancel()
    }

    // MARK: Backup

    /// Starts a backup. A user-started backup on iOS 26 runs as a continued-processing task, so it
    /// keeps going after the user leaves the app, with progress in the system UI.
    /// - Parameter automatic: true when iOS started it in the background overnight.
    func backUpNow(automatic: Bool = false) async {
        guard !isStarting else { return }
        if isRunInProgress {
            // A run in the app, without a continued-processing task, freezes once iOS suspends the app,
            // and can sit there for hours waiting to retry. Stop it and start again under the task this
            // start brings: the overnight processing time, or a new continued-processing task.
            guard systemTask == nil, let previous = activeRun else { return }
            log.notice("Restarting the backup running in the app (automatic: \(automatic))")
            previous.cancel()
            await previous.value
            guard !isRunInProgress else { return }
        }
        if automatic {
            lastAutomaticRun = .now
        } else if #available(iOS 26, *), ContinuedBackup.submit(client: self) {
            log.info("Continued-processing request accepted; waiting for iOS to start it")
            isStarting = true
            defer { isStarting = false }
            phase = .searching
            // iOS can accept the request without starting it right away. Don't sit there: if its
            // handler hasn't begun within a few seconds, back up in the app instead.
            try? await Task.sleep(for: .seconds(3))
            guard !isRunInProgress else { return }
            log.notice("iOS hasn't started the continued task after 3 s; backing up in the app")
        }
        await run(automatic: automatic, systemTask: nil)
    }

    /// Resumes a backup that stopped part-way, e.g. when iOS suspended the app. Called when the app opens.
    /// A run that is still going in the app is restarted, so it gets a continued-processing task.
    func resumeIfUnfinished() {
        guard unfinished != nil, credential != nil, systemTask == nil else { return }
        Task { await backUpNow() }
    }

    /// Runs the backup, retrying dropped connections. Every retry resumes from the bytes the Mac already has.
    /// - Returns: false if a backup was already running, so this call did nothing.
    @discardableResult
    func run(automatic: Bool, systemTask: AnyObject?) async -> Bool {
        guard !isRunInProgress else {
            log.info("A backup is already running; ignoring the second start")
            return false
        }
        isRunInProgress = true
        let body = Task { await performRun(automatic: automatic, systemTask: systemTask) }
        activeRun = body
        await withTaskCancellationHandler { await body.value } onCancel: { body.cancel() }
        return true
    }

    private func performRun(automatic: Bool, systemTask: AnyObject?) async {
        log.info("Backup started (automatic: \(automatic), system task: \(systemTask != nil))")
        self.systemTask = systemTask
        runManifest = nil
        reportedUnits = 0
        sessionFileCount = 0
        sessionFilesDone = 0
        reportToSystem()
        let heartbeat = systemTask == nil ? nil : Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.keepProgressMoving()
            }
        }
        defer {
            heartbeat?.cancel()
            self.systemTask = nil
            runManifest = nil
            activeRun = nil
            isRunInProgress = false
        }

        // Without a continued-processing task, iOS suspends the app soon after it leaves the screen,
        // which drops the connection. Keep the screen on while the app is open, and ask for extra time
        // when the user switches away so the current file can finish.
        UIApplication.shared.isIdleTimerDisabled = true
        let backgroundTask = BackgroundTime()
        if !automatic && systemTask == nil { backgroundTask.begin() }
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            backgroundTask.end()
        }

        var attempt = 0
        var searches = 0
        while true {
            sessionFilesDone = 0
            do {
                phase = try await runSession()
                log.info("Backup finished")
                lastBackup = .now
                unfinished = nil
                break
            } catch where error is CancellationError || Task.isCancelled {
                // Cancelling also ends the connection, so the error can look like a dropped reply.
                // iOS stopping the task isn't a failure: `unfinished` is kept, and the backup resumes
                // when the app next opens.
                log.notice("Backup cancelled (\(String(describing: error), privacy: .public))")
                phase = .idle
                break
            } catch {
                log.error("Backup attempt \(attempt + 1) failed: \(String(describing: error), privacy: .public)")
                // Without a continued-processing task iOS suspends the app soon after it leaves the screen,
                // and a suspended app's connections are torn down (ECONNABORTED when it wakes). Retrying
                // then just fails again and uses up the retries, so stop here; `unfinished` is kept and
                // the backup resumes when the app next opens.
                if !automatic, self.systemTask == nil, UIApplication.shared.applicationState != .active, Self.isRetryable(error) {
                    log.notice("Pausing: the app is in the background without a continued-processing task")
                    phase = .idle
                    break
                }
                // A session that sent files before dropping was working; only count drops in a row.
                if sessionFilesDone > 0 { attempt = 0 }
                if case BackupServiceError.serverNotFound = error { searches += 1 } else { searches = 0 }
                guard Self.isRetryable(error), attempt < Self.maxRetries, searches < Self.maxSearches, !Task.isCancelled else {
                    phase = .failed(error.localizedDescription)
                    break
                }
                attempt += 1
                let delay = min(60, 2 << attempt)
                // Nothing is moving while we wait, so let the screen lock as usual.
                UIApplication.shared.isIdleTimerDisabled = false
                retryRequested = false
                for remaining in stride(from: delay, to: 0, by: -1) {
                    phase = .waitingToRetry(attempt: attempt, seconds: remaining, reason: Self.describe(error))
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled || retryRequested { break }
                }
                retryRequested = false
                UIApplication.shared.isIdleTimerDisabled = true
                if Task.isCancelled { phase = .idle; break }
            }
        }
        await refreshCounts()
    }

    /// Skips the rest of the wait before the next reconnect attempt.
    func retryNow() {
        guard case .waitingToRetry = phase else { return }
        retryRequested = true
    }

    /// Network trouble is worth retrying; a refusal from the Mac or missing permission isn't.
    private static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case is ClientError:
            if case .unexpectedReply = error as! ClientError { return true }   // usually a connection cut mid-reply
            return false
        case is PhotoLibrary.ExportError:
            return false
        default:
            return true   // NWError, POSIX errors, Mac not found on the network
        }
    }

    private static func describe(_ error: Error) -> String {
        if case BackupServiceError.serverNotFound = error { return "Can't find your Mac on this Wi-Fi." }
        if case PeerConnection.PeerError.lostNetwork = error { return "Wi-Fi connection lost." }
        if case PeerConnection.PeerError.stalled = error { return "Your Mac stopped responding." }
        return "The connection to your Mac dropped."
    }

    /// Records progress within the current step; reported to iOS at most a few times a second.
    private func setStepFraction(_ fraction: Double) {
        let fraction = min(max(fraction, 0), 1)
        guard fraction > stepFraction else { return }
        stepFraction = fraction
        guard Date.now.timeIntervalSince(stepFractionChanged) > 0.5 else { return }
        stepFractionChanged = .now
        reportToSystem()
    }

    private func startStep() {
        stepFraction = 0
        stepFractionChanged = .now
    }

    /// iOS checks the task's progress every so often and stops it if nothing moved. Some waits report
    /// nothing for a while (a reconnect, an iCloud download that hasn't started, the Mac hashing a
    /// long video), so creep forward a little whenever there's been no real progress for a few seconds.
    private func keepProgressMoving() {
        guard Date.now.timeIntervalSince(lastReport) >= 3 else { return }
        reportToSystem(creep: true)
    }

    /// The whole run as one 0...1 estimate: connecting and comparing take the first 5%, the files this
    /// session sends the rest. Counted over this session's files, not the library, so every file moves it.
    private var estimatedFraction: Double {
        switch phase {
        case .searching, .connecting: 0.01 * stepFraction
        case .comparing: 0.01 + 0.04 * stepFraction
        case .uploading:
            0.05 + 0.95 * (Double(sessionFilesDone) + stepFraction) / Double(max(sessionFileCount, 1))
        case .finished: 1
        default: 0
        }
    }

    /// Mirrors progress into the iOS 26 system progress UI for a continued-processing task.
    private func reportToSystem(creep: Bool = false) {
        guard #available(iOS 26, *), let task = systemTask as? BGContinuedProcessingTask else { return }
        let total = Self.systemUnits
        var units = max(reportedUnits, Int64(estimatedFraction * Double(total)))
        if creep && units == reportedUnits {
            // Move at least a little, slowing as it nears the end so it never gets there first.
            units = reportedUnits + max(1, (total - reportedUnits) / 400)
        }
        if case .finished = phase {} else { units = min(units, total - 1) }
        if units > reportedUnits { lastReport = .now }
        reportedUnits = units
        task.progress.totalUnitCount = total
        task.progress.completedUnitCount = units
        if Date.now.timeIntervalSince(lastProgressLog) >= 10 {
            lastProgressLog = .now
            log.info("System progress \(units)/\(total) (\(String(describing: self.phase), privacy: .public))")
        }

        switch phase {
        case .searching, .connecting:
            task.updateTitle("Backing up photos", subtitle: "Connecting to \(credential?.serverName ?? "your Mac")…")
        case .comparing:
            task.updateTitle("Backing up photos", subtitle: "Comparing with your Mac…")
        case .uploading(let done, let total, let current):
            task.updateTitle("Backing up \(done.formatted()) of \(total.formatted())", subtitle: current)
        case .waitingToRetry(_, let seconds, let reason):
            task.updateTitle("Waiting for your Mac", subtitle: "\(reason) Retrying in \(seconds)s.")
        default:
            break
        }
    }

    private func runSession() async throws -> Phase {
        guard let credential else { throw ClientError.notPaired }
        guard await PhotoLibrary.requestAccess() else { throw ClientError.noPhotosAccess }

        startStep()
        phase = .searching
        let (peer, connectedReplies) = try await connect(credential) { self.phase = .connecting }
        var replies = connectedReplies
        defer { peer.cancel() }
        let reports = unsentReports
        if !reports.isEmpty { try await peer.withDeadline(Self.sendTimeout, "sending to your Mac") { try await peer.send(.control(.changeReport(reports))) } }

        startStep()
        phase = .comparing
        let manifest: [ManifestEntry]
        if let runManifest {
            manifest = runManifest
        } else {
            log.info("Scanning the library")
            manifest = await Task.detached(priority: .userInitiated) {
                PhotoLibrary.scan { fraction in
                    Task { @MainActor [weak self] in self?.setStepFraction(fraction * 0.7) }
                }
            }.value
            runManifest = manifest
            log.info("Scanned \(manifest.count) items")
        }
        var needs: [ResumePoint] = []
        for start in stride(from: 0, to: manifest.count, by: Self.manifestBatchSize) {
            try Task.checkCancellation()
            setStepFraction(0.7 + 0.3 * Double(start) / Double(max(manifest.count, 1)))
            let batch = Array(manifest[start..<min(start + Self.manifestBatchSize, manifest.count)])
            try await peer.withDeadline(Self.sendTimeout, "sending to your Mac") { try await peer.send(.control(.manifest(batch))) }
            guard case .control(.need(let batchNeeds))? = try await peer.withDeadline(Self.replyTimeout, "waiting for your Mac", { try await replies.next(isolation: #isolation) }) else { throw ClientError.unexpectedReply }
            needs += batchNeeds
        }
        try await peer.withDeadline(Self.sendTimeout, "sending to your Mac") { try await peer.send(.control(.manifestEnd(albums: PhotoLibrary.albumTitles()))) }
        guard case .control(.changes(let changes))? = try await peer.withDeadline(Self.replyTimeout, "waiting for your Mac", { try await replies.next(isolation: #isolation) }) else { throw ClientError.unexpectedReply }
        // The Mac handles frames in order, so it recorded the reports before replying.
        unsentReports.removeAll { reports.contains($0) }
        receive(changes)

        var lookup: [ResourceKey: (AssetMetadata, ResourceDescriptor)] = [:]
        for entry in manifest {
            for resource in entry.resources { lookup[resource.key] = (entry.metadata, resource) }
        }

        // Count progress in photos and videos across the whole library: an asset is done once
        // every one of its files is on the Mac.
        var filesLeft: [String: Int] = [:]
        for need in needs { filesLeft[need.key.assetID, default: 0] += 1 }
        var assetsDone = manifest.count - filesLeft.count
        unfinished = needs.isEmpty ? nil : Progress(done: assetsDone, total: manifest.count)

        var sent = 0
        var failed = 0
        sessionFileCount = needs.count
        sessionFilesDone = 0
        for need in needs {
            try Task.checkCancellation()
            guard let (metadata, descriptor) = lookup[need.key] else { continue }
            startStep()
            phase = .uploading(done: assetsDone, total: manifest.count, current: descriptor.originalFilename)
            var stored = false
            do {
                try await Self.upload(descriptor, metadata: metadata, from: need.offset, over: peer) { fraction in
                    Task { @MainActor [weak self] in self?.setStepFraction(fraction) }
                }
                switch try await peer.withDeadline(Self.verifyTimeout, "waiting for your Mac to check the file", { try await replies.next(isolation: #isolation) }) {
                case .control(.stored)?: sent += 1; stored = true
                case .control(.failed)?: failed += 1
                default: throw ClientError.unexpectedReply
                }
            } catch is PhotoLibrary.ExportError {
                failed += 1
            }
            sessionFilesDone += 1
            if stored, let left = filesLeft[need.key.assetID] {
                if left <= 1 {
                    filesLeft[need.key.assetID] = nil
                    assetsDone += 1
                } else {
                    filesLeft[need.key.assetID] = left - 1
                }
                unfinished = Progress(done: assetsDone, total: manifest.count)
            }
        }

        try await peer.withDeadline(Self.sendTimeout, "sending to your Mac") { try await peer.send(.control(.goodbye)) }
        return .finished(sent: sent, failed: failed)
    }

    /// Finds the Mac, opens an encrypted connection with this phone's key and says hello.
    /// Returns once the Mac welcomes it; throws if the Mac turns it away. The caller cancels the connection.
    func connect(
        _ credential: DeviceCredential, found: () -> Void = {}
    ) async throws -> (PeerConnection, AsyncThrowingStream<Frame, Error>.Iterator) {
        log.info("Looking for the Mac on the network")
        let endpoint = try await BackupService.findServer(id: credential.serverID)

        log.info("Found the Mac; connecting")
        found()
        let peer = PeerConnection(endpoint: endpoint, parameters: BackupService.parameters(
            secret: credential.key, identity: credential.deviceID
        ))
        do {
            do {
                try await peer.withDeadline(Self.connectTimeout, "connecting") { try await peer.start() }
            } catch let error as NWError {
                // A TLS failure means the Mac doesn't know this phone's key. Anything else is network trouble.
                if case .tls = error {
                    throw ClientError.refused("Your Mac didn't accept this iPhone. If you removed it on the Mac, unpair here and pair again.")
                }
                throw error
            }
            var replies = peer.frames.makeAsyncIterator()

            guard let binding = peer.keyingMaterial(label: HelloProof.exporterLabel) else { throw ClientError.unexpectedReply }
            try await peer.withDeadline(Self.sendTimeout, "sending to your Mac") { try await peer.send(.control(.hello(
                deviceID: credential.deviceID, deviceName: deviceName, protocolVersion: ProtocolVersion.current,
                proof: HelloProof.make(key: credential.key, deviceID: credential.deviceID, binding: binding)
            ))) }
            switch try await peer.withDeadline(Self.replyTimeout, "waiting for your Mac", { try await replies.next(isolation: #isolation) }) {
            case .control(.welcome)?: return (peer, replies)
            case .control(.unavailable(let reason))?: throw ClientError.refused(reason)
            default: throw ClientError.unexpectedReply
            }
        } catch {
            peer.cancel()
            throw error
        }
    }

    /// Exports one file and streams it from `offset`, so an interrupted video resumes where it stopped.
    /// `progress` gets 0...1: the iCloud download (if any) is the first half, sending the second.
    private nonisolated static func upload(
        _ descriptor: ResourceDescriptor, metadata: AssetMetadata, from offset: UInt64, over peer: PeerConnection,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let url = try await PhotoLibrary.export(descriptor.key) { progress($0 * 0.5) }
        defer { try? FileManager.default.removeItem(at: url) }

        let size = UInt64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let sha256 = try FileHasher.sha256(of: url)
        try await peer.withDeadline(Self.sendTimeout, "sending to your Mac") { try await peer.send(.control(.beginResource(descriptor, metadata: metadata, size: size))) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var position = offset <= size ? offset : 0
        try handle.seek(toOffset: position)
        while let data = try handle.read(upToCount: FrameCodec.chunkSize), !data.isEmpty {
            try await peer.withDeadline(Self.sendTimeout, "sending to your Mac") { try await peer.send(.chunk(key: descriptor.key, offset: position, data: data)) }
            position += UInt64(data.count)
            progress(0.5 + 0.5 * Double(position) / Double(max(size, 1)))
        }
        try await peer.withDeadline(Self.sendTimeout, "sending to your Mac") { try await peer.send(.control(.endResource(descriptor.key, sha256: sha256))) }
    }

    // MARK: Changes from the Mac

    /// Takes the Mac's current list of changes, at a backup or over the live link. With "apply right
    /// away" on and the app on screen, they're made straight away (deletions still ask in iOS's own
    /// prompt); otherwise they wait for the user to review them.
    func receive(_ changes: [LibraryChange]) {
        macChanges = changes.filter { !handledChangeIDs.contains($0.id) }
        // Arrived while Imago isn't on screen (an overnight backup): tell the user, once per change.
        let fresh = macChanges.filter { !notifiedChangeIDs.contains($0.id) }
        if !fresh.isEmpty, UIApplication.shared.applicationState != .active {
            MacChangeNotifications.post(macChanges, mac: credential?.serverName ?? "Your Mac")
            notifiedChangeIDs = Array((notifiedChangeIDs + fresh.map(\.id)).suffix(500))
        }
        scheduleAutoApply()
    }

    /// Changes the user has already been notified about.
    private var notifiedChangeIDs: [UUID] {
        get { (UserDefaults.standard.array(forKey: "notifiedChangeIDs") as? [String] ?? []).compactMap(UUID.init) }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: "notifiedChangeIDs") }
    }

    /// Applies changes that arrived while the app was in the background, e.g. at an overnight backup.
    func applyWaitingChanges() {
        scheduleAutoApply()
    }

    private func scheduleAutoApply() {
        guard applyRightAway, autoApply == nil, !macChanges.isEmpty else { return }
        autoApply = Task {
            defer { autoApply = nil }
            // Changes made together on the Mac arrive one after another; wait a moment so deletions go in one prompt.
            try? await Task.sleep(for: .seconds(1.5))
            // Putting photos back adds to the library: always the user's call, in the review.
            while applyRightAway, UIApplication.shared.applicationState == .active, macChanges.contains(where: { $0.action != .restore }) {
                let batch = macChanges.filter { $0.action != .restore }
                await review(approve: batch, decline: [])
                // Stop if nothing was handled (e.g. a review was already running); more may have arrived meanwhile.
                if macChanges.allSatisfy(batch.contains) { break }
            }
        }
    }

    /// Makes the approved changes and turns down the rest. All deletions go in one request, so iOS
    /// asks once. The Mac hears what happened at the next backup.
    func review(approve approved: [LibraryChange], decline declined: [LibraryChange]) async {
        guard !isApplyingChanges else { return }
        isApplyingChanges = true
        defer { isApplyingChanges = false }

        var reports = declined.map { ChangeReport(changeID: $0.id, outcome: .declined, assetCount: 0) }
        // Put-backs need the files from the Mac: asked for now over the live link, reported when they're in.
        let restores = approved.filter { $0.action == .restore && !restoringIDs.contains($0.id) }
        if !restores.isEmpty {
            if let requestRestoreNow {
                restoreNeedsConnection = false
                for change in restores {
                    restoringIDs.insert(change.id)
                    requestRestoreNow(change)
                }
            } else {
                restoreNeedsConnection = true
            }
        }
        let deletions = approved.filter { $0.action == .delete }
        for change in approved where change.action != .delete && change.action != .restore {
            reports.append(await PhotoLibrary.apply(change))
        }
        if !deletions.isEmpty {
            let combined = LibraryChange(action: .delete, assetIDs: deletions.flatMap(\.assetIDs))
            let result = await PhotoLibrary.apply(combined)
            for change in deletions {
                reports.append(ChangeReport(changeID: change.id, outcome: result.outcome,
                                            assetCount: result.outcome == .applied ? change.assetIDs.count : 0, detail: result.detail))
            }
        }

        let ids = Set(reports.map(\.changeID))
        unsentReports += reports
        // Over the live link the Mac hears now. They're also sent at the next backup, in case this
        // doesn't arrive; the Mac ignores reports it already has.
        sendReportsNow?(reports)
        handledChangeIDs = Array((handledChangeIDs + ids).suffix(500))
        macChanges.removeAll { ids.contains($0.id) }
        await refreshCounts()
    }

    /// A put-back finished (or couldn't be done): the Mac hears now, or at the next backup.
    func finishRestore(_ report: ChangeReport) async {
        restoringIDs.remove(report.changeID)
        unsentReports.append(report)
        sendReportsNow?([report])
        handledChangeIDs = Array((handledChangeIDs + [report.changeID]).suffix(500))
        macChanges.removeAll { $0.id == report.changeID }
        await refreshCounts()
    }

    /// The live link dropped mid-way: the put-backs on their way wait for the next connection.
    func restoresInterrupted() {
        guard !restoringIDs.isEmpty else { return }
        restoringIDs = []
        restoreNeedsConnection = true
    }

    /// The live link is up again: put-backs approved while it wasn't go now.
    func resumeWaitingRestores() {
        guard restoreNeedsConnection, let requestRestoreNow else { return }
        restoreNeedsConnection = false
        for change in macChanges where change.action == .restore && !restoringIDs.contains(change.id) {
            restoringIDs.insert(change.id)
            requestRestoreNow(change)
        }
    }

    private struct ChangeState: Codable {
        var pending: [LibraryChange]
        var unsent: [ChangeReport]
        var handled: [UUID]
    }

    /// A file rather than UserDefaults: a big clean-up can list thousands of photos.
    private static var changeStateURL: URL {
        URL.applicationSupportDirectory.appending(path: "mac-changes.json")
    }

    private func saveChangeState() {
        let state = ChangeState(pending: macChanges, unsent: unsentReports, handled: handledChangeIDs)
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: Self.changeStateURL, options: .atomic)
    }

    private func loadChangeState() {
        guard let data = try? Data(contentsOf: Self.changeStateURL),
              let state = try? JSONDecoder().decode(ChangeState.self, from: data) else { return }
        macChanges = state.pending
        unsentReports = state.unsent
        handledChangeIDs = state.handled
    }

    /// Kept in the Keychain so it survives reinstalling the app; the Mac then keeps using the same folder.
    private static var deviceID: String {
        if let data = Keychain.load(account: deviceIDAccount), let id = String(data: data, encoding: .utf8) { return id }
        let id = UUID().uuidString
        try? Keychain.save(Data(id.utf8), account: deviceIDAccount)
        return id
    }
}

/// Extra running time from iOS after the user leaves the app (about 30 seconds), so the file being sent
/// can finish. Ended when the backup ends or iOS says time is up.
@MainActor
private final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "Photo backup") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
