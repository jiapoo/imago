import AppKit
import Foundation
import IOKit.pwr_mgt
import Network
import Observation
import ImagoKit
import SwiftUI

/// Advertises the Mac on the local network, pairs iPhones, and runs one backup session per
/// connected phone. Each phone backs up into its own folder under the chosen location.
@MainActor @Observable
final class BackupServer {
    enum NetworkStatus: Equatable {
        case stopped
        case listening
        case failed(String)
    }

    struct Session: Identifiable {
        let id: UUID
        var deviceID: String?
        var received = 0
        var total = 0
        var currentFile: String?
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let date = Date()
        let symbol: String
        let text: String
    }

    let serverID: String
    let serverName: String

    private(set) var networkStatus: NetworkStatus = .stopped
    private(set) var devices: [PairedDevice]
    private(set) var summaries: [String: BackupStore.Summary] = [:]
    private(set) var sessions: [UUID: Session] = [:]
    private(set) var log: [LogLine] = []
    private(set) var location: LocationInfo
    /// External and network drives currently mounted, for the Storage page's quick picks.
    private(set) var drives: [LocationInfo] = []
    /// Non-nil while "Add iPhone" is open.
    private(set) var pairingCode: PairingInfo?
    /// The phone that just finished pairing, for the success screen.
    private(set) var justPaired: PairedDevice?
    /// Bumped when a phone's library snapshot or change queue changes, so open views reload.
    private(set) var libraryRevision: [String: Int] = [:]
    /// The location's `library.json`: its ID and which phone owns which folder. Nil while the
    /// location is unavailable.
    private(set) var library: LibraryRecord?
    /// Bumped when files arrive or the location changes, so the library browser reloads.
    private(set) var catalogRevision = 0
    /// Phones with Imago open right now, which get changes the moment they're made.
    private(set) var liveDevices: Set<String> = []
    /// Previews the phones sent of assets not backed up yet: device ID → asset ID → JPEG file.
    private(set) var previews: [String: [String: URL]] = [:]

    private var livePeers: [String: (session: UUID, peer: PeerConnection)] = [:]
    /// Each phone's protocol version, from its last hello: changes it doesn't know aren't sent to it.
    private var phoneVersions: [String: Int] = [:]
    private let driveKeepAwake = DriveKeepAwake()
    private var appActivationObservers: [NSObjectProtocol] = []
    private var isAppActive = false
    private var requestedPreviews: [String: Set<String>] = [:]
    private var previewQueue: [String: [String]] = [:]

    private var keys: [String: Data]
    private var stores: [String: BackupStore] = [:]
    private var listener: NWListener?
    private var pairingListener: NWListener?
    private var accessedURL: URL?
    private var sleepAssertion: IOPMAssertionID?

    private static let bookmarkKey = "backupLocationBookmark"
    private static let pathKey = "backupLocationPath"
    static var defaultLocation: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appending(path: "Photo Backup", directoryHint: .isDirectory)
    }

    init() {
        if let id = UserDefaults.standard.string(forKey: "serverID") {
            serverID = id
        } else {
            serverID = UUID().uuidString
            UserDefaults.standard.set(serverID, forKey: "serverID")
        }
        serverName = Host.current().localizedName ?? "Mac"
        devices = DeviceRegistry.loadDevices()
        #if DEBUG
        // A sample library (`-BackupLocation`) is for trying the app, not backups: an unsigned
        // test build reading the real pairing keys would make macOS ask for the Keychain password.
        keys = UserDefaults.standard.string(forKey: "BackupLocation") == nil ? DeviceRegistry.loadKeys() : [:]
        #else
        keys = DeviceRegistry.loadKeys()
        #endif
        location = LocationInfo(url: Self.defaultLocation)

        refreshLocation()
        watchDrives()
    }

    // MARK: Status

    var totalAssets: Int { summaries.values.reduce(0) { $0 + $1.assetCount } }
    var totalBytes: UInt64 { summaries.values.reduce(0) { $0 + $1.totalBytes } }
    var lastBackup: Date? { summaries.values.compactMap(\.lastBackup).max() }
    var isBackingUp: Bool { sessions.values.contains { $0.deviceID != nil } }

    func session(for device: PairedDevice) -> Session? {
        sessions.values.first { $0.deviceID == device.id }
    }

    // MARK: Network

    func start() {
        startBackupListener()
        watchAppActivation()
    }

    /// While Imago is the active app the backup drive is kept spinning, so it's awake (a spinning
    /// drive takes 10–25 seconds to wake) by the time a photo or video is opened.
    private func watchAppActivation() {
        let center = NotificationCenter.default
        appActivationObservers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAppActive(true) }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAppActive(false) }
            },
        ]
    }

    private func setAppActive(_ active: Bool) {
        guard active != isAppActive else { return }
        isAppActive = active
        keepDriveAwake(active)
    }

    private func startBackupListener() {
        listener?.cancel()
        var psks = devices.compactMap { device in
            keys[device.id].map { BackupService.PreSharedKey(identity: device.id, key: $0) }
        }
        // TLS needs at least one key; a random one admits nobody.
        if psks.isEmpty { psks = [.init(identity: "none", key: Secret.random())] }
        do {
            let listener = try NWListener(using: BackupService.parameters(keys: psks))
            listener.service = BackupService.advertisement(serverID: serverID, name: serverName, mode: .backup)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.acceptBackup(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            networkStatus = .failed(error.localizedDescription)
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready: networkStatus = .listening
        case .failed(let error): networkStatus = .failed(error.localizedDescription)
        case .cancelled: break
        default: break
        }
    }

    // MARK: Pairing

    /// Opens the pairing service with a fresh one-time code. Call when "Add iPhone" appears.
    func beginPairing() {
        pairingListener?.cancel()
        justPaired = nil
        let code = PairingInfo(serverID: serverID, serverName: serverName, secret: Secret.random())
        pairingCode = code
        do {
            let listener = try NWListener(using: BackupService.parameters(
                secret: code.secret, identity: BackupService.pairingIdentity
            ))
            listener.service = BackupService.advertisement(serverID: serverID, name: serverName, mode: .pair)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.acceptPairing(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    Task { @MainActor in self?.addLog("Pairing unavailable: \(error.localizedDescription)", symbol: "exclamationmark.triangle") }
                }
            }
            listener.start(queue: .main)
            pairingListener = listener
        } catch {
            addLog("Couldn't start pairing: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }

    func endPairing() {
        pairingListener?.cancel()
        pairingListener = nil
        pairingCode = nil
    }

    private func acceptPairing(_ connection: NWConnection) {
        let peer = PeerConnection(connection: connection)
        Task {
            defer { peer.cancel() }
            do {
                try await peer.start()
                var frames = peer.frames.makeAsyncIterator()
                guard case .control(.pairRequest(let deviceID, let deviceName, let version))? = try await frames.next(),
                      ProtocolVersion.supported.contains(version)
                else { return }

                let key = Secret.random()
                let device = register(deviceID: deviceID, name: deviceName, key: key)
                try await peer.send(.control(.paired(deviceKey: key, serverName: serverName)))
                justPaired = device
                addLog("Paired \(device.name)", symbol: "checkmark.circle")
                // One code, one phone: anyone who saw this code can't use it again.
                if pairingCode != nil { beginPairing(); justPaired = device }
            } catch {
                addLog("Pairing failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
        }
    }

    /// Adds the phone, or gives an already-known phone a new key and keeps its folder.
    private func register(deviceID: String, name: String, key: Data) -> PairedDevice {
        let device: PairedDevice
        if let index = devices.firstIndex(where: { $0.id == deviceID }) {
            devices[index].name = name
        } else {
            let folder = DeviceRegistry.folderName(
                for: name, taken: Set(devices.map(\.folder)), in: location.url
            )
            devices.append(PairedDevice(id: deviceID, name: name, folder: folder, pairedAt: .now))
            // Paired with another Mac before, or with this one before it was removed.
            if let known = library?.device(deviceID) {
                addLog("Found \(name)'s earlier backups in “\(known.folder)”", symbol: "folder")
            }
        }
        reconcileLibrary()
        device = devices.first { $0.id == deviceID }!
        keys[deviceID] = key
        DeviceRegistry.saveKeys(keys)
        startBackupListener()
        Task { await refreshSummaries() }
        return device
    }

    /// The phone can no longer connect. Its photos stay in its folder.
    func remove(_ device: PairedDevice) {
        devices.removeAll { $0.id == device.id }
        keys[device.id] = nil
        stores[device.id] = nil
        summaries[device.id] = nil
        DeviceRegistry.saveDevices(devices)
        DeviceRegistry.saveKeys(keys)
        startBackupListener()
        addLog("Removed \(device.name)", symbol: "iphone.slash")
    }

    /// The iPhone's color as hex: the one picked for it, or by the order it was paired.
    func colorHex(of deviceID: String) -> String {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return PairedDevice.defaultColors[0] }
        return devices[index].colorHex ?? PairedDevice.defaultColors[index % PairedDevice.defaultColors.count]
    }

    func color(of deviceID: String) -> Color {
        Color(hex: colorHex(of: deviceID))
    }

    func setColor(_ hex: String, for device: PairedDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }), devices[index].colorHex != hex else { return }
        devices[index].colorHex = hex
        DeviceRegistry.saveDevices(devices)
    }

    func rename(_ device: PairedDevice, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index].name = trimmed
        reconcileLibrary()
    }

    // MARK: Backup sessions

    private func acceptBackup(_ connection: NWConnection) {
        let id = UUID()
        sessions[id] = Session(id: id)
        Task { await runBackup(PeerConnection(connection: connection), id: id) }
    }

    private func runBackup(_ peer: PeerConnection, id: UUID) async {
        var store: BackupStore?
        var device: PairedDevice?
        var manifest: [ManifestEntry] = []
        /// A live session rather than a backup (version 5).
        var isLive = false
        let started = Date()
        updateSleepAssertion()
        do {
            try await peer.start()
            for try await frame in peer.frames {
                switch frame {
                case .control(.hello(let deviceID, let deviceName, let version, let proof)):
                    guard ProtocolVersion.supported.contains(version) else {
                        try await peer.send(.control(.unavailable(
                            reason: "Update Imago on this iPhone and on your Mac so both are on the same version."
                        )))
                        peer.cancel()
                        break
                    }
                    // TLS accepted one of our keys; the proof shows it was this phone's own.
                    guard let known = devices.first(where: { $0.id == deviceID }), let key = keys[deviceID],
                          let proof, let binding = peer.keyingMaterial(label: HelloProof.exporterLabel),
                          HelloProof.isValid(proof, key: key, deviceID: deviceID, binding: binding)
                    else {
                        try await peer.send(.control(.unavailable(reason: "Pair this iPhone with your Mac again.")))
                        peer.cancel()
                        break
                    }
                    if known.name != deviceName { rename(known, to: deviceName) }
                    refreshLocation()
                    guard let deviceStore = self.store(for: known) else {
                        try await peer.send(.control(.unavailable(
                            reason: "Your Mac's backup drive “\(location.volumeName)” isn't connected."
                        )))
                        addLog("\(known.name) tried to back up, but “\(location.volumeName)” isn't connected", symbol: "externaldrive.badge.xmark")
                        peer.cancel()
                        break
                    }
                    store = deviceStore
                    device = devices.first { $0.id == deviceID }
                    phoneVersions[deviceID] = version
                    sessions[id]?.deviceID = deviceID
                    try await peer.send(.control(.welcome(serverName: serverName)))

                case .control(.manifest(let entries)):
                    // At a backup, and over the live link after something changed on the iPhone: then
                    // only the list is wanted, not the files (the iPhone ignores the answer).
                    guard let store else { peer.cancel(); break }
                    manifest += entries
                    let needs = await store.resumePoints(for: entries)
                    sessions[id]?.total += needs.count
                    try await peer.send(.control(.need(needs)))

                case .control(.beginResource(let descriptor, let metadata, let size)):
                    try await store?.begin(descriptor, metadata: metadata, size: size)
                    sessions[id]?.currentFile = descriptor.originalFilename

                case .chunk(let key, let offset, let data):
                    try await store?.append(data, to: key, at: offset)

                case .control(.endResource(let key, let sha256)):
                    do {
                        try await store?.finish(key, sha256: sha256)
                        sessions[id]?.received += 1
                        try await peer.send(.control(.stored(key)))
                        // Keep the counts on screen moving during a long backup.
                        if let device, let store, (sessions[id]?.received ?? 0) % 20 == 0 {
                            summaries[device.id] = await store.summary()
                        }
                    } catch {
                        addLog(error.localizedDescription, symbol: "exclamationmark.triangle")
                        try await peer.send(.control(.failed(key, reason: error.localizedDescription)))
                    }

                case .control(.manifestEnd(let albums)):
                    guard let store, let device else { peer.cancel(); break }
                    do {
                        try await store.saveSnapshot(PhoneSnapshot(takenAt: .now, entries: manifest, albums: albums))
                    } catch {
                        addLog("Couldn't save \(device.name)'s library list: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
                    }
                    manifest = []
                    let pending = sendable(await store.changeQueue().pending, to: device.id)
                    try await peer.send(.control(.changes(pending)))
                    // Over the live link the list comes after each change on the iPhone, and the
                    // changes went when it connected: no need to say so again.
                    if !pending.isEmpty, !isLive {
                        addLog("Sent \(pending.count) \(pending.count == 1 ? "change" : "changes") to \(device.name) to review", symbol: "iphone.and.arrow.forward")
                    }
                    libraryChanged(device.id)

                case .control(.changeReport(let reports)):
                    guard let store, let device else { break }
                    let recorded = (try? await store.record(reports)) ?? []
                    for done in recorded {
                        let verb = switch done.report.outcome {
                        case .applied: "did"
                        case .declined: "declined"
                        case .failed: "couldn't do"
                        }
                        addLog("\(device.name) \(verb): \(done.change.summary)", symbol: done.report.outcome == .applied ? "checkmark.circle" : "xmark.circle")
                    }
                    // Files from the Mac the phone couldn't add: plain files here again, Not synced.
                    let adds = recorded.filter(\.change.addsFromMac)
                    let added = Set(adds.compactMap(\.report.restored).flatMap(\.keys))
                    let notAdded = Set(adds.flatMap(\.change.assetIDs)).subtracting(added)
                    if !notAdded.isEmpty {
                        // Turned down on the iPhone: not offered again by itself, only if sent by hand.
                        let refused = Set(adds.filter { $0.report.outcome == .declined }.flatMap(\.change.assetIDs)).intersection(notAdded)
                        let files = await store.storedFiles(of: Array(refused))
                        declinedAdds.formUnion(files.values.flatMap { $0.map(\.url.path) })
                        try? await store.unadopt(notAdded)
                        catalogRevision += 1
                    }
                    let declined = recorded.filter { $0.report.outcome == .declined && !$0.change.addsFromMac }.map(\.change)
                    if !declined.isEmpty { MacNotifications.declined(declined, on: device.name) }
                    libraryChanged(device.id)
                    // Put back under new IDs: the library reads the files' new names.
                    if recorded.contains(where: { $0.report.restored?.isEmpty == false }) { catalogRevision += 1 }

                case .control(.live):
                    guard let store, let device else { peer.cancel(); break }
                    // Not a backup: it doesn't show as one or keep the Mac awake.
                    isLive = true
                    sessions[id] = nil
                    updateSleepAssertion()
                    livePeers[device.id] = (id, peer)
                    liveDevices.insert(device.id)
                    requestedPreviews[device.id] = []
                    try await peer.send(.control(.changes(sendable(await store.changeQueue().pending, to: device.id))))
                    addLog("Imago is open on \(device.name): changes go to it right away", symbol: "iphone.radiowaves.left.and.right")
                    libraryChanged(device.id)

                case .control(.thumbnails(let thumbnails)):
                    guard let device else { break }
                    savePreviews(thumbnails, for: device.id)

                case .control(.restoreRequest(let changeID)):
                    guard let store, let device else { break }
                    try await sendRestore(changeID, from: store, to: device, over: peer)

                case .control(.goodbye):
                    // A live session says goodbye too, but it backed nothing up.
                    if let device, !isLive { await store?.recordBackup(deviceID: device.id) }
                    peer.cancel()

                default:
                    break
                }
            }
        } catch {
            if let device, !isLive {
                addLog("\(device.name) disconnected; it will resume next time", symbol: "wifi.exclamationmark")
            }
        }

        if let device, livePeers[device.id]?.session == id {
            livePeers[device.id] = nil
            liveDevices.remove(device.id)
            libraryChanged(device.id)
        }
        await store?.flush()
        if let session = sessions.removeValue(forKey: id), let device, session.received > 0 {
            addLog("\(device.name): backed up \(session.received) files", symbol: "checkmark.circle")
            if let store { warmThumbnails(store, since: started) }
        }
        updateSleepAssertion()
        guard !isLive else { return }
        await refreshSummaries()
        catalogRevision += 1
    }

    /// Keeps the Mac from idle-sleeping mid-transfer. It can't wake a sleeping Mac; for overnight
    /// backups turn on "Wake for network access" in System Settings.
    private func updateSleepAssertion() {
        if !sessions.isEmpty, sleepAssertion == nil {
            var assertion = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Backing up photos from iPhone" as CFString,
                &assertion
            )
            if result == kIOReturnSuccess { sleepAssertion = assertion }
        } else if sessions.isEmpty, let assertion = sleepAssertion {
            IOPMAssertionRelease(assertion)
            sleepAssertion = nil
        }
    }

    // MARK: Phone library

    private func libraryChanged(_ deviceID: String) {
        libraryRevision[deviceID, default: 0] += 1
    }

    /// Queues a change for the phone. It's sent at the phone's next backup and only happens once
    /// the user confirms it there.
    func request(_ action: LibraryChange.Action, for assets: [PhoneAsset], on device: PairedDevice) {
        guard let store = store(for: device), !assets.isEmpty else { return }
        // Only what's fully on the Mac may be deleted from the phone.
        let targets = action == .delete ? assets.filter(\.isBackedUp) : assets
        guard !targets.isEmpty else { return }
        let change = LibraryChange(
            action: action, assetIDs: targets.map(\.id),
            bytes: action == .delete ? targets.reduce(0) { $0 + $1.bytes } : nil
        )
        let base = Dictionary(targets.map { ($0.id, $0.metadata) }, uniquingKeysWith: { a, _ in a })
        Task {
            do {
                if let queued = try await store.enqueue(change, base: base) {
                    addLog((liveDevices.contains(device.id) ? "Sent to \(device.name): " : "Queued for \(device.name): ") + queued.summary,
                           symbol: queued.symbol)
                }
            } catch {
                addLog("Couldn't queue the change: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
            libraryChanged(device.id)
            await pushChanges(to: device.id, from: store)
        }
    }

    /// The changes this phone's version understands; the rest wait until its Imago is updated.
    private func sendable(_ changes: [LibraryChange], to deviceID: String) -> [LibraryChange] {
        let version = phoneVersions[deviceID] ?? ProtocolVersion.current
        return changes.filter { $0.action.minimumVersion <= version }
    }

    /// Asks the phone to delete an album, as Photos does: its photos stay in the library. Returns the
    /// change's ID, to take it back.
    @discardableResult
    func requestAlbumDeletion(_ title: String, on device: PairedDevice, base: [String: AssetMetadata]) -> UUID? {
        guard let store = store(for: device) else { return nil }
        let change = LibraryChange(action: .deleteAlbum(title), assetIDs: [])
        Task {
            do {
                if let queued = try await store.enqueue(change, base: base) {
                    addLog((liveDevices.contains(device.id) ? "Sent to \(device.name): " : "Queued for \(device.name): ") + queued.summary,
                           symbol: queued.symbol)
                }
            } catch {
                addLog("Couldn't queue the change: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
            libraryChanged(device.id)
            await pushChanges(to: device.id, from: store)
        }
        return change.id
    }

    /// Asks the phone to put these backed-up assets back in its library: ones deleted there that the
    /// user wants back. The phone asks first, then fetches the files over the live link.
    func requestRestore(_ assetIDs: [String], on device: PairedDevice) {
        guard let store = store(for: device), !assetIDs.isEmpty else { return }
        enqueue(LibraryChange(action: .restore, assetIDs: assetIDs), on: device, store: store)
    }

    /// Not synced files an iPhone said no to: they wait until sent by hand.
    var declinedAdds: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "declinedAdds") ?? []) {
        didSet { UserDefaults.standard.set(Array(declinedAdds), forKey: "declinedAdds") }
    }

    /// Sends files on the drive that an iPhone doesn't have (an edited copy, a file from Finder) to
    /// add to its Photos library. Each becomes one of its assets here first (`BackupStore.adopt`), then
    /// goes like a put-back; an iPhone with this version adds it without asking. Returns how many went.
    @discardableResult
    func send(_ items: [MediaItem], to device: PairedDevice) async -> Int {
        guard let store = store(for: device) else { return 0 }
        var ids: [String] = []
        for item in items where item.deviceID == nil {
            let metadata = AssetMetadata(
                assetID: "", originalFilename: item.name, creationDate: item.date, modificationDate: nil,
                mediaType: item.isVideo ? "video" : "image", pixelWidth: 0, pixelHeight: 0, duration: item.duration,
                isFavorite: false,
                location: item.latitude.flatMap { lat in item.longitude.map { .init(latitude: lat, longitude: $0, altitude: 0) } },
                albums: []
            )
            do {
                ids.append(try await store.adopt(item.url, metadata: metadata, kind: item.isVideo ? .video : .photo))
                declinedAdds.remove(item.url.path)
            } catch BackupStore.AdoptError.alreadyThere {
                continue
            } catch {
                addLog("Couldn't send \(item.name) to \(device.name): \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
        }
        guard !ids.isEmpty else { return 0 }
        enqueue(LibraryChange(action: .restore, assetIDs: ids, isNew: true), on: device, store: store)
        catalogRevision += 1
        return ids.count
    }

    /// Takes assets out of waiting put-backs.
    func withdrawRestore(_ assetIDs: Set<String>, on device: PairedDevice) {
        guard let store = store(for: device) else { return }
        Task {
            try? await store.withdraw(assetIDs, from: .restore)
            // Files from the Mac taken back before they went: plain files here again.
            if assetIDs.contains(where: { $0.hasPrefix("mac-") }) {
                try? await store.unadopt(assetIDs)
                catalogRevision += 1
            }
            libraryChanged(device.id)
            await pushChanges(to: device.id, from: store)
        }
    }

    /// Asks again for a change the phone turned down, once: it shows there as asked a second time.
    func askAgain(_ change: LibraryChange, on device: PairedDevice) {
        guard let store = store(for: device) else { return }
        enqueue(LibraryChange(action: change.action, assetIDs: change.assetIDs, bytes: change.bytes, round: (change.round ?? 1) + 1),
                on: device, store: store)
    }

    /// Records what the user decided about a change the phone turned down.
    func resolve(_ change: LibraryChange, as resolution: ChangeQueue.Resolution, on device: PairedDevice) async {
        try? await store(for: device)?.resolve(change.id, as: resolution)
        libraryChanged(device.id)
    }

    private func enqueue(_ change: LibraryChange, on device: PairedDevice, store: BackupStore) {
        Task {
            do {
                if let queued = try await store.enqueue(change, base: [:]) {
                    addLog((liveDevices.contains(device.id) ? "Sent to \(device.name): " : "Queued for \(device.name): ") + queued.summary,
                           symbol: queued.symbol)
                }
            } catch {
                addLog("Couldn't queue the change: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
            // The library notes what it asked for itself (`MediaLibrary.restoring`, `pendingRemoval`):
            // re-reading every item for one queued change would take seconds on a big library.
            libraryChanged(device.id)
            await pushChanges(to: device.id, from: store)
        }
    }

    /// Sends the files of a restore the user approved on the phone: each asset's details, then its
    /// originals in chunks, read off the drive away from the main thread.
    private func sendRestore(_ changeID: UUID, from store: BackupStore, to device: PairedDevice, over peer: PeerConnection) async throws {
        guard let change = await store.changeQueue().pending.first(where: { $0.id == changeID }), change.action == .restore else {
            try await peer.send(.control(.restoreEnd(changeID, missing: [])))
            return
        }
        let assets = await store.restoreAssets(change.assetIDs)
        let found = Set(assets.map(\.asset.metadata.assetID))
        addLog("Sending \(assets.count) \(assets.count == 1 ? "item" : "items") back to \(device.name)", symbol: "arrow.uturn.backward.circle")
        for (asset, urls) in assets {
            try await peer.send(.control(.restoreAsset(asset)))
            for (file, url) in zip(asset.files, urls) {
                guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? handle.close() }
                var offset: UInt64 = 0
                while true {
                    let data = await Task.detached(priority: .userInitiated) { (try? handle.read(upToCount: FrameCodec.chunkSize)) ?? Data() }.value
                    guard !data.isEmpty else { break }
                    try await peer.send(.chunk(key: file.key, offset: offset, data: data))
                    offset += UInt64(data.count)
                }
            }
        }
        try await peer.send(.control(.restoreEnd(changeID, missing: change.assetIDs.filter { !found.contains($0) })))
    }

    /// Takes back a waiting change by its ID.
    func cancelChange(_ id: UUID, on device: PairedDevice) {
        guard let store = store(for: device) else { return }
        Task {
            let change = await store.changeQueue().pending.first { $0.id == id }
            try? await store.cancelChange(id)
            if let change, change.addsFromMac {
                try? await store.unadopt(Set(change.assetIDs))
                catalogRevision += 1
            }
            libraryChanged(device.id)
            await pushChanges(to: device.id, from: store)
        }
    }

    /// Keeps assets on the phone after all: takes them out of the deletions waiting for it.
    func keep(_ assetIDs: Set<String>, on device: PairedDevice) {
        guard let store = store(for: device) else { return }
        Task {
            try? await store.withdraw(assetIDs, from: .delete)
            libraryChanged(device.id)
            await pushChanges(to: device.id, from: store)
        }
    }

    func cancel(_ change: LibraryChange, on device: PairedDevice) {
        guard let store = store(for: device) else { return }
        Task {
            try? await store.cancelChange(change.id)
            if change.addsFromMac {
                try? await store.unadopt(Set(change.assetIDs))
                catalogRevision += 1
            }
            libraryChanged(device.id)
            await pushChanges(to: device.id, from: store)
        }
    }

    /// Makes grid thumbnails for what a backup brought in, while those files are fresh, so browsing
    /// later doesn't read thousands of originals off a slow or sleeping drive. One at a time, at
    /// background priority: tiles on screen go first.
    private func warmThumbnails(_ store: BackupStore, since date: Date) {
        Task.detached(priority: .background) {
            for file in await store.displayFiles(storedSince: date, limit: 5000) {
                await Thumbnails.shared.waitForBackgroundTurn()
                _ = await Thumbnails.shared.image(for: file.url, bytes: file.bytes)
            }
        }
    }

    // MARK: Live sessions

    /// Sends the whole queue to the phone if Imago is open on it. The phone drops changes it has
    /// already handled, and ones no longer in the queue were cancelled here.
    private func pushChanges(to deviceID: String, from store: BackupStore) async {
        guard let live = livePeers[deviceID] else { return }
        let pending = sendable(await store.changeQueue().pending, to: deviceID)
        do {
            try await live.peer.send(.control(.changes(pending)))
        } catch {
            live.peer.cancel()
        }
    }

    /// Asks the phone, if Imago is open on it, for a preview of an asset the Mac has no copy of yet.
    /// Tiles ask as they scroll into view; requests made close together go out as one message.
    /// Each asset is asked for once per session.
    func requestPreview(_ assetID: String, on device: PairedDevice) {
        guard livePeers[device.id] != nil, previews[device.id]?[assetID] == nil,
              requestedPreviews[device.id]?.contains(assetID) == false else { return }
        requestedPreviews[device.id, default: []].insert(assetID)
        let first = previewQueue[device.id, default: []].isEmpty
        previewQueue[device.id, default: []].append(assetID)
        guard first else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            let wanted = previewQueue.removeValue(forKey: device.id) ?? []
            guard let live = livePeers[device.id] else { return }
            // Small batches, so the first previews show while the rest are made.
            for start in stride(from: 0, to: wanted.count, by: 60) {
                let batch = Array(wanted[start..<min(start + 60, wanted.count)])
                do { try await live.peer.send(.control(.thumbnailRequest(batch))) } catch { live.peer.cancel(); return }
            }
        }
    }

    /// Previews live on this Mac's own disk, not the backup drive: they're replaced by the real
    /// photo once it's backed up.
    private static var previewsDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "PhonePreviews", directoryHint: .isDirectory)
    }

    private func savePreviews(_ thumbnails: [Thumbnail], for deviceID: String) {
        let folder = Self.previewsDirectory.appending(path: deviceID, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var known = previews[deviceID] ?? [:]
        for thumbnail in thumbnails {
            let name = thumbnail.assetID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
            let file = folder.appending(path: name + ".jpg")
            if (try? thumbnail.jpeg.write(to: file, options: .atomic)) != nil { known[thumbnail.assetID] = file }
        }
        previews[deviceID] = known
    }

    /// Previews saved in earlier sessions.
    func loadPreviews(for device: PairedDevice) {
        guard previews[device.id] == nil else { return }
        let folder = Self.previewsDirectory.appending(path: device.id, directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        previews[device.id] = Dictionary(files.compactMap { file in
            file.deletingPathExtension().lastPathComponent.removingPercentEncoding.map { ($0, file) }
        }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Location

    func store(for device: PairedDevice) -> BackupStore? {
        guard location.isAvailable else { return nil }
        if let store = stores[device.id] { return store }
        let store = BackupStore(root: location.url.appending(path: device.folder, directoryHint: .isDirectory), deviceID: device.id)
        stores[device.id] = store
        return store
    }

    /// Where the user's own folders live, e.g. "Tennis": the top of the backup location, next to the
    /// phones' folders and Recently Deleted.
    var foldersURL: URL {
        location.url
    }

    /// Top-level names that aren't the user's folders: every phone's folder, including phones removed
    /// since (the library record keeps them, and their backups stay), and Recently Deleted.
    var reservedFolderNames: Set<String> {
        Set(devices.map(\.folder) + (library?.devices.map(\.folder) ?? [])
            + [trashFolder.split(separator: "/").first.map(String.init) ?? trashFolder])
    }

    /// Recently Deleted: a folder in the library (path relative to it), "Recently Deleted" unless
    /// chosen in Settings. Inside the library, so deleting and putting back are quick renames, and
    /// iPhone items keep their sidecars.
    private(set) var trashFolder: String = UserDefaults.standard.string(forKey: "trashFolder") ?? "Recently Deleted"
    /// Days items stay in Recently Deleted; 0 keeps them until emptied.
    var trashDays: Int = UserDefaults.standard.object(forKey: "trashDays") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(trashDays, forKey: "trashDays") }
    }

    var trashURL: URL {
        location.url.appending(path: trashFolder, directoryHint: .isDirectory)
    }

    /// Uses `url` for Recently Deleted. It must be inside the library and outside Folders and the
    /// iPhones' folders. Returns why not, if it can't be used.
    func setTrashFolder(_ url: URL) -> String? {
        let root = location.url.lexicallyStandardized.pathComponents
        let parts = url.lexicallyStandardized.pathComponents
        guard parts.count > root.count, Array(parts.prefix(root.count)) == root else {
            return "Choose a folder inside the backup location, “\(location.displayPath)”, so deleting and putting back are instant."
        }
        let inside = Array(parts.dropFirst(root.count))
        if inside.count != 1 || devices.contains(where: { $0.folder == inside.first }) {
            return "Choose a folder at the top of the backup location, not inside another folder or an iPhone's folder."
        }
        // Items already there would need their iPhone records moved too: empty it first.
        let left = (try? FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        if !left.isEmpty, url.lexicallyStandardized != trashURL.lexicallyStandardized {
            return "Empty Recently Deleted first, or put its items back. Then choose the new folder."
        }
        trashFolder = inside.joined(separator: "/")
        UserDefaults.standard.set(trashFolder, forKey: "trashFolder")
        catalogRevision += 1
        return nil
    }

    func folderURL(for device: PairedDevice) -> URL {
        location.url.appending(path: device.folder, directoryHint: .isDirectory)
    }

    func refreshSummaries() async {
        var fresh: [String: BackupStore.Summary] = [:]
        for device in devices {
            if let store = store(for: device) { fresh[device.id] = await store.summary() }
            else if let old = summaries[device.id] { fresh[device.id] = old }
        }
        summaries = fresh
    }

    /// Keeps the backup drive spinning while a photo page is open (see `DriveKeepAwake`). Balanced: each
    /// `true` needs a `false`.
    func keepDriveAwake(_ on: Bool) {
        if on {
            driveKeepAwake.begin { [weak self] in await self?.recentFiles(for: nil, limit: 40) ?? [] }
        } else {
            driveKeepAwake.end()
        }
    }

    func recentFiles(for device: PairedDevice?, limit: Int) async -> [URL] {
        var files: [URL] = []
        for candidate in devices where device == nil || candidate.id == device?.id {
            if let store = store(for: candidate) { files += await store.recentFiles(limit: limit) }
        }
        return Array(files.prefix(limit))
    }

    func chooseLocation(startingAt start: URL? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose where Imago keeps your photos. External and network drives work too."
        panel.directoryURL = start ?? (location.isAvailable ? location.url : nil)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            UserDefaults.standard.set(url.path(percentEncoded: false), forKey: Self.pathKey)
        } catch {
            addLog("Couldn't use that folder: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            return
        }
        refreshLocation()
        addLog("Backups now go to \(location.displayPath)", symbol: location.symbol)
    }

    func useDefaultLocation() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: Self.pathKey)
        refreshLocation()
        addLog("Backups now go to \(location.displayPath)", symbol: location.symbol)
    }

    var isUsingDefaultLocation: Bool {
        UserDefaults.standard.data(forKey: Self.bookmarkKey) == nil
    }

    func revealInFinder(_ url: URL? = nil) {
        NSWorkspace.shared.activateFileViewerSelecting([url ?? location.url])
    }

    /// Re-reads the chosen folder, e.g. after a drive is plugged in or removed.
    func refreshLocation() {
        let url = resolveLocationURL()
        let info = LocationInfo(url: url)
        if info.url != location.url || info.isAvailable != location.isAvailable {
            stores.removeAll()
        }
        location = info
        catalogRevision += 1
        reconcileLibrary()
        refreshDrives()
        Task { await refreshSummaries() }
    }

    /// Reads the location's `library.json`, creating it for a folder that has none, and makes each
    /// paired phone use the folder it lists, so a library brought from another Mac, or moved to a
    /// new drive, keeps every phone's backups where they are. Phones it doesn't list yet are added.
    private func reconcileLibrary() {
        defer { DeviceRegistry.saveDevices(devices) }
        guard location.isAvailable else {
            library = nil
            return
        }
        let existing: LibraryRecord?
        do {
            existing = try LibraryRecord.load(from: location.url)
        } catch {
            // Never overwrite a record we can't read; keep using the folders this Mac knows.
            addLog("Couldn't read “\(LibraryRecord.relativePath)”: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            library = nil
            return
        }
        var record = existing ?? LibraryRecord()
        for index in devices.indices {
            let folder = record.folder(for: devices[index].id, name: devices[index].name, preferred: devices[index].folder)
            if folder != devices[index].folder {
                stores[devices[index].id] = nil
                devices[index].folder = folder
            }
        }
        if record != existing {
            do {
                try record.save(to: location.url)
            } catch {
                addLog("Couldn't save this library's details: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
        }
        library = record
    }

    private func refreshDrives() {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        drives = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false, values.volumeIsReadOnly != true,
                  values.volumeIsInternal == false || values.volumeIsLocal == false
            else { return nil }
            return LocationInfo(url: url)
        }
    }

    /// Bytes used by everything on the backup volume other than Imago's own files.
    var otherBytesOnVolume: Int64? {
        guard let total = location.totalBytes, let free = location.availableBytes else { return nil }
        return max(0, total - free - Int64(totalBytes))
    }

    private func resolveLocationURL() -> URL {
        #if DEBUG
        // Test hook: `-BackupLocation <folder>` uses that folder, e.g. a sample library.
        if let path = UserDefaults.standard.string(forKey: "BackupLocation") {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        #endif
        if let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                if accessedURL != url {
                    accessedURL?.stopAccessingSecurityScopedResource()
                    _ = url.startAccessingSecurityScopedResource()
                    accessedURL = url
                }
                if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
                }
                return url
            }
            // The drive is unplugged; remember where it was so the UI can name it.
            if let path = UserDefaults.standard.string(forKey: Self.pathKey) {
                return URL(filePath: path, directoryHint: .isDirectory)
            }
        }
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        let url = Self.defaultLocation
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func watchDrives() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLocation() }
            }
        }
    }

    private func addLog(_ text: String, symbol: String) {
        log.insert(LogLine(symbol: symbol, text: text), at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
    }
}

// MARK: - Health

struct Health {
    var symbol: String
    var tint: Color
    var title: String
    var subtitle: String
}

extension BackupServer {
    var health: Health {
        if devices.isEmpty {
            return Health(symbol: "iphone", tint: .blue, title: "Add your iPhone to start",
                          subtitle: "Pair an iPhone and its photos back up to this Mac over Wi-Fi.")
        }
        if !location.isAvailable {
            return Health(symbol: "externaldrive.fill.badge.xmark", tint: .orange, title: "Backup drive not connected",
                          subtitle: "Connect “\(location.volumeName)” and backups pick up where they left off.")
        }
        if isBackingUp {
            let names = sessions.values.compactMap { s in devices.first { $0.id == s.deviceID }?.name }
            return Health(symbol: "arrow.triangle.2.circlepath", tint: .blue, title: "Backing up…",
                          subtitle: "Receiving photos from \(ListFormatter.localizedString(byJoining: names)).")
        }
        if let partial = devices.first(where: { summaries[$0.id]?.isPartial == true && summaries[$0.id]?.lastBackup == nil }) {
            return Health(symbol: "pause.circle.fill", tint: .orange, title: "First backup not finished",
                          subtitle: "\(totalAssets.formatted()) photos and videos so far. Open Imago on \(partial.name) to finish; it continues where it stopped.")
        }
        guard let last = lastBackup else {
            return Health(symbol: "clock", tint: .secondary, title: "Waiting for the first backup",
                          subtitle: "Open Imago on your iPhone and tap Back Up Now.")
        }
        let days = Int(Date.now.timeIntervalSince(last) / 86_400)
        if days >= 3 {
            return Health(symbol: "exclamationmark.shield.fill", tint: .yellow, title: "No backup in \(days) days",
                          subtitle: "Open Imago on your iPhone, or leave it charging on Wi-Fi tonight.")
        }
        return Health(symbol: "checkmark.shield.fill", tint: .green, title: "Your photos are protected",
                      subtitle: "\(totalAssets.formatted()) photos and videos, last backed up \(last.formatted(.relative(presentation: .named))).")
    }
}
