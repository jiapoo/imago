import Foundation
import Observation
import Photos
import PhotoBackupKit
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
            case .noPhotosAccess: "Photo Backup needs access to your photos. Turn it on in Settings › Privacy › Photos."
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
    private(set) var credential: DeviceCredential?
    private(set) var isPairing = false
    private(set) var photoCount = 0
    private(set) var videoCount = 0
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
    /// Connection drops are retried this many times, waiting 4, 8, 16, 32, then 60 seconds.
    private static let maxRetries = 8

    init() {
        if let data = Keychain.load(account: Self.credentialAccount) {
            credential = try? JSONDecoder().decode(DeviceCredential.self, from: data)
        }
        lastBackup = UserDefaults.standard.object(forKey: "lastBackup") as? Date
        lastAutomaticRun = UserDefaults.standard.object(forKey: "lastAutomaticRun") as? Date
        deviceName = UserDefaults.standard.string(forKey: "deviceName") ?? Self.systemDeviceName
        overnightBackup = UserDefaults.standard.object(forKey: "overnightBackup") as? Bool ?? true
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
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
                || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else { return }
        photoCount = PHAsset.fetchAssets(with: .image, options: nil).count
        videoCount = PHAsset.fetchAssets(with: .video, options: nil).count
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
        guard !phase.isRunning, !isRunInProgress else { return }
        if automatic {
            lastAutomaticRun = .now
        } else if #available(iOS 26, *), ContinuedBackup.submit() {
            log.info("Continued-processing request accepted; waiting for iOS to start it")
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
    func resumeIfUnfinished() {
        guard unfinished != nil, credential != nil, !phase.isRunning else { return }
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
        log.info("Backup started (automatic: \(automatic), system task: \(systemTask != nil))")
        self.systemTask = systemTask
        defer {
            self.systemTask = nil
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
        while true {
            do {
                phase = try await runSession()
                log.info("Backup finished")
                lastBackup = .now
                unfinished = nil
                break
            } catch is CancellationError {
                log.notice("Backup cancelled")
                phase = .idle
                break
            } catch {
                log.error("Backup attempt \(attempt + 1) failed: \(String(describing: error), privacy: .public)")
                guard Self.isRetryable(error), attempt < Self.maxRetries, !Task.isCancelled else {
                    phase = .failed(error.localizedDescription)
                    break
                }
                attempt += 1
                let delay = min(60, 2 << attempt)
                for remaining in stride(from: delay, to: 0, by: -1) {
                    phase = .waitingToRetry(attempt: attempt, seconds: remaining, reason: Self.describe(error))
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { break }
                }
                if Task.isCancelled { phase = .idle; break }
            }
        }
        await refreshCounts()
        return true
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
        return "The connection to your Mac dropped."
    }

    /// Mirrors progress into the iOS 26 system progress UI for a continued-processing task.
    private func reportToSystem() {
        guard #available(iOS 26, *), let task = systemTask as? BGContinuedProcessingTask else { return }
        switch phase {
        case .searching, .connecting:
            task.updateTitle("Backing up photos", subtitle: "Connecting to \(credential?.serverName ?? "your Mac")…")
        case .comparing:
            task.updateTitle("Backing up photos", subtitle: "Comparing with your Mac…")
        case .uploading(let done, let total, let current):
            task.progress.totalUnitCount = Int64(max(total, 1))
            task.progress.completedUnitCount = Int64(done)
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

        phase = .searching
        log.info("Looking for the Mac on the network")
        let endpoint = try await BackupService.findServer(id: credential.serverID)

        log.info("Found the Mac; connecting")
        phase = .connecting
        let peer = PeerConnection(endpoint: endpoint, parameters: BackupService.parameters(
            secret: credential.key, identity: credential.deviceID
        ))
        defer { peer.cancel() }
        do {
            try await peer.start()
        } catch let error as NWError {
            // A TLS failure means the Mac doesn't know this phone's key. Anything else is network trouble.
            if case .tls = error {
                throw ClientError.refused("Your Mac didn't accept this iPhone. If you removed it on the Mac, unpair here and pair again.")
            }
            throw error
        }
        var replies = peer.frames.makeAsyncIterator()

        guard let binding = peer.keyingMaterial(label: HelloProof.exporterLabel) else { throw ClientError.unexpectedReply }
        try await peer.send(.control(.hello(
            deviceID: credential.deviceID, deviceName: deviceName, protocolVersion: ProtocolVersion.current,
            proof: HelloProof.make(key: credential.key, deviceID: credential.deviceID, binding: binding)
        )))
        switch try await replies.next() {
        case .control(.welcome)?: break
        case .control(.unavailable(let reason))?: throw ClientError.refused(reason)
        default: throw ClientError.unexpectedReply
        }
        let reports = unsentReports
        if !reports.isEmpty { try await peer.send(.control(.changeReport(reports))) }

        phase = .comparing
        let manifest = await Task.detached(priority: .userInitiated) { PhotoLibrary.scan() }.value
        var needs: [ResumePoint] = []
        for start in stride(from: 0, to: manifest.count, by: Self.manifestBatchSize) {
            try Task.checkCancellation()
            let batch = Array(manifest[start..<min(start + Self.manifestBatchSize, manifest.count)])
            try await peer.send(.control(.manifest(batch)))
            guard case .control(.need(let batchNeeds))? = try await replies.next() else { throw ClientError.unexpectedReply }
            needs += batchNeeds
        }
        try await peer.send(.control(.manifestEnd(albums: PhotoLibrary.albumTitles())))
        guard case .control(.changes(let changes))? = try await replies.next() else { throw ClientError.unexpectedReply }
        // The Mac handles frames in order, so it recorded the reports before replying.
        unsentReports.removeAll { reports.contains($0) }
        macChanges = changes.filter { !handledChangeIDs.contains($0.id) }

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
        for need in needs {
            try Task.checkCancellation()
            guard let (metadata, descriptor) = lookup[need.key] else { continue }
            phase = .uploading(done: assetsDone, total: manifest.count, current: descriptor.originalFilename)
            var stored = false
            do {
                try await Self.upload(descriptor, metadata: metadata, from: need.offset, over: peer)
                switch try await replies.next() {
                case .control(.stored)?: sent += 1; stored = true
                case .control(.failed)?: failed += 1
                default: throw ClientError.unexpectedReply
                }
            } catch is PhotoLibrary.ExportError {
                failed += 1
            }
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

        try await peer.send(.control(.goodbye))
        return .finished(sent: sent, failed: failed)
    }

    /// Exports one file and streams it from `offset`, so an interrupted video resumes where it stopped.
    private nonisolated static func upload(
        _ descriptor: ResourceDescriptor, metadata: AssetMetadata, from offset: UInt64, over peer: PeerConnection
    ) async throws {
        let url = try await PhotoLibrary.export(descriptor.key)
        defer { try? FileManager.default.removeItem(at: url) }

        let size = UInt64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let sha256 = try FileHasher.sha256(of: url)
        try await peer.send(.control(.beginResource(descriptor, metadata: metadata, size: size)))

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var position = offset <= size ? offset : 0
        try handle.seek(toOffset: position)
        while let data = try handle.read(upToCount: FrameCodec.chunkSize), !data.isEmpty {
            try await peer.send(.chunk(key: descriptor.key, offset: position, data: data))
            position += UInt64(data.count)
        }
        try await peer.send(.control(.endResource(descriptor.key, sha256: sha256)))
    }

    // MARK: Changes from the Mac

    /// Makes the approved changes and turns down the rest. All deletions go in one request, so iOS
    /// asks once. The Mac hears what happened at the next backup.
    func review(approve approved: [LibraryChange], decline declined: [LibraryChange]) async {
        guard !isApplyingChanges else { return }
        isApplyingChanges = true
        defer { isApplyingChanges = false }

        var reports = declined.map { ChangeReport(changeID: $0.id, outcome: .declined, assetCount: 0) }
        let deletions = approved.filter { $0.action == .delete }
        for change in approved where change.action != .delete {
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
        handledChangeIDs = Array((handledChangeIDs + ids).suffix(500))
        macChanges.removeAll { ids.contains($0.id) }
        await refreshCounts()
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
