import AppKit
import Foundation
import IOKit.pwr_mgt
import Network
import Observation
import PhotoBackupKit
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
                      version == ProtocolVersion.current
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
        updateSleepAssertion()
        do {
            try await peer.start()
            for try await frame in peer.frames {
                switch frame {
                case .control(.hello(let deviceID, let deviceName, let version, let proof)):
                    guard version == ProtocolVersion.current else {
                        try await peer.send(.control(.unavailable(
                            reason: "Update Photo Backup on this iPhone and on your Mac so both are on the same version."
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
                    sessions[id]?.deviceID = deviceID
                    try await peer.send(.control(.welcome(serverName: serverName)))

                case .control(.manifest(let entries)):
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
                    let pending = await store.changeQueue().pending
                    try await peer.send(.control(.changes(pending)))
                    if !pending.isEmpty {
                        addLog("Sent \(pending.count) \(pending.count == 1 ? "change" : "changes") to \(device.name) to review", symbol: "iphone.and.arrow.forward")
                    }
                    libraryChanged(device.id)

                case .control(.changeReport(let reports)):
                    guard let store, let device else { break }
                    for done in (try? await store.record(reports)) ?? [] {
                        let verb = switch done.report.outcome {
                        case .applied: "did"
                        case .declined: "declined"
                        case .failed: "couldn't do"
                        }
                        addLog("\(device.name) \(verb): \(done.change.summary)", symbol: done.report.outcome == .applied ? "checkmark.circle" : "xmark.circle")
                    }
                    libraryChanged(device.id)

                case .control(.goodbye):
                    if let device { await store?.recordBackup(deviceID: device.id) }
                    peer.cancel()

                default:
                    break
                }
            }
        } catch {
            if let device {
                addLog("\(device.name) disconnected; it will resume next time", symbol: "wifi.exclamationmark")
            }
        }

        await store?.flush()
        if let session = sessions.removeValue(forKey: id), let device, session.received > 0 {
            addLog("\(device.name): backed up \(session.received) files", symbol: "checkmark.circle")
        }
        updateSleepAssertion()
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
        Task {
            do {
                try await store.enqueue(change)
                addLog("Queued for \(device.name): \(change.summary)", symbol: change.symbol)
            } catch {
                addLog("Couldn't queue the change: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
            libraryChanged(device.id)
        }
    }

    func cancel(_ change: LibraryChange, on device: PairedDevice) {
        guard let store = store(for: device) else { return }
        Task {
            try? await store.cancelChange(change.id)
            libraryChanged(device.id)
        }
    }

    // MARK: Location

    func store(for device: PairedDevice) -> BackupStore? {
        guard location.isAvailable else { return nil }
        if let store = stores[device.id] { return store }
        let store = BackupStore(root: location.url.appending(path: device.folder, directoryHint: .isDirectory), deviceID: device.id)
        stores[device.id] = store
        return store
    }

    /// Where the library's own folders live, e.g. "Tennis", next to the phones' folders.
    var foldersURL: URL {
        location.url.appending(path: MediaLibrary.foldersName, directoryHint: .isDirectory)
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
        panel.message = "Choose where Photo Backup keeps your photos. External and network drives work too."
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

    /// Bytes used by everything on the backup volume other than Photo Backup's own files.
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
                          subtitle: "\(totalAssets.formatted()) photos and videos so far. Open Photo Backup on \(partial.name) to finish; it continues where it stopped.")
        }
        guard let last = lastBackup else {
            return Health(symbol: "clock", tint: .secondary, title: "Waiting for the first backup",
                          subtitle: "Open Photo Backup on your iPhone and tap Back Up Now.")
        }
        let days = Int(Date.now.timeIntervalSince(last) / 86_400)
        if days >= 3 {
            return Health(symbol: "exclamationmark.shield.fill", tint: .yellow, title: "No backup in \(days) days",
                          subtitle: "Open Photo Backup on your iPhone, or leave it charging on Wi-Fi tonight.")
        }
        return Health(symbol: "checkmark.shield.fill", tint: .green, title: "Your photos are protected",
                      subtitle: "\(totalAssets.formatted()) photos and videos, last backed up \(last.formatted(.relative(presentation: .named))).")
    }
}
