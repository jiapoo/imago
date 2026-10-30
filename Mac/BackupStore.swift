import Foundation
import ImagoKit

/// Owns the backup folder: partial uploads, verified moves into the dated layout, sidecars,
/// and a fast index. The index is a cache; `rebuildIndex()` recreates it from the sidecars.
actor BackupStore {
    struct StoredResource: Codable {
        var assetID: String
        var relativePath: String
        var sha256: String
        var size: UInt64
        var storedAt: Date
    }

    struct Index: Codable {
        var resources: [String: StoredResource] = [:]   // keyed by ResourceKey.description
        var lastBackupByDevice: [String: Date] = [:]
        /// Each asset's metadata and sidecar, keyed by asset ID, so the library can be shown without
        /// reading every sidecar. Indexes from before it existed fill it in on first browse.
        var assets: [String: AssetRecord] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            resources = try container.decode([String: StoredResource].self, forKey: .resources)
            lastBackupByDevice = try container.decode([String: Date].self, forKey: .lastBackupByDevice)
            assets = try container.decodeIfPresent([String: AssetRecord].self, forKey: .assets) ?? [:]
        }
    }

    struct AssetRecord: Codable {
        var metadata: AssetMetadata
        /// Path of its sidecar, relative to `root`. Nil until it's been looked up.
        var sidecar: String?
    }

    /// One asset as the library browser shows it.
    struct CatalogEntry: Sendable {
        struct File: Sendable {
            var kind: ResourceKind
            var url: URL
            var size: UInt64
            var sha256: String
        }

        var assetID: String
        var metadata: AssetMetadata
        var files: [File]

        /// What to show: the original, or the rendered edit if that's all there is.
        var display: File? {
            files.first { $0.kind == .photo || $0.kind == .video }
                ?? files.first { $0.kind == .fullSizePhoto || $0.kind == .fullSizeVideo }
        }
    }

    struct Summary: Equatable, Sendable {
        var assetCount = 0
        var fileCount = 0
        var totalBytes: UInt64 = 0
        /// When the phone last finished a whole backup.
        var lastBackup: Date?
        /// When the last file arrived, finished backup or not.
        var lastReceived: Date?

        /// Files have arrived since the last complete backup (or there hasn't been one yet).
        var isPartial: Bool {
            guard let lastReceived else { return false }
            return lastBackup.map { lastReceived > $0 } ?? true
        }
    }

    enum StoreError: LocalizedError {
        case notStarted(ResourceKey)
        case checksumMismatch(ResourceKey)
        case sizeMismatch(ResourceKey, expected: UInt64, actual: UInt64)

        var errorDescription: String? {
            switch self {
            case .notStarted(let key): "Received data for \(key) before it was started."
            case .checksumMismatch(let key): "Checksum mismatch for \(key); it will be sent again."
            case .sizeMismatch(let key, let expected, let actual): "\(key) is \(actual) bytes, expected \(expected)."
            }
        }
    }

    private struct InFlight {
        var descriptor: ResourceDescriptor
        var metadata: AssetMetadata
        var size: UInt64
        var url: URL
        var handle: FileHandle
    }

    nonisolated let root: URL
    /// The phone this folder belongs to, written into every sidecar.
    nonisolated let deviceID: String
    private let layout = LibraryLayout()
    /// Read on first use, on the actor, not in `init`: the server makes stores on the main actor,
    /// and a slow or failing drive would freeze the app there.
    private lazy var storedIndex: Index = (try? JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))) ?? Index()
    /// Counts changes to the index, so what's worked out from it (`catalog`) is kept until it changes.
    /// Every change goes through `index`, so none is missed.
    private var indexVersion = 0
    private var index: Index {
        _read { yield storedIndex }
        _modify {
            indexVersion &+= 1
            yield &storedIndex
        }
        set {
            indexVersion &+= 1
            storedIndex = newValue
        }
    }
    private var catalogCache: (version: Int, entries: [CatalogEntry])?
    /// The phone's last library list as saved, and the file's date then (see `savedSnapshot`).
    var snapshotCache: (modified: Date, snapshot: PhoneSnapshot)?
    /// For `relink`: the index's files by name, and the files already looked for in it.
    private var relinkCache: (version: Int, byName: [String: [String]], checked: Set<URL>)?
    private var inFlight: [ResourceKey: InFlight] = [:]
    private var unsavedChanges = 0
    private var lastIndexSave = ContinuousClock.now
    private let fileManager = FileManager.default

    nonisolated var stateDirectory: URL { root.appending(path: ".photobackup", directoryHint: .isDirectory) }
    private nonisolated var partialDirectory: URL { stateDirectory.appending(path: "partial", directoryHint: .isDirectory) }
    private nonisolated var indexURL: URL { stateDirectory.appending(path: "index.json") }
    private nonisolated var skipURL: URL { stateDirectory.appending(path: "skip.json") }
    /// Files moved to the Trash on the Mac, by key. The phone isn't asked for them again.
    private lazy var skipped: Set<String> = (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: skipURL))) ?? []

    private var hasStateDirectory = false

    init(root: URL, deviceID: String) {
        self.root = root
        self.deviceID = deviceID
    }

    /// Makes `.photobackup` and its partial folder before anything is written there.
    func prepareStateDirectory() throws {
        guard !hasStateDirectory else { return }
        try fileManager.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
        hasStateDirectory = true
    }

    // MARK: Receiving

    /// What the phone should send for this manifest batch, resuming partial files where possible.
    func resumePoints(for manifest: [ManifestEntry]) -> [ResumePoint] {
        manifest.flatMap(\.resources).compactMap { resource in
            let key = resource.key.description
            guard index.resources[key] == nil, !skipped.contains(key) else { return nil }
            let partialSize = (try? partialURL(for: resource.key).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return ResumePoint(key: resource.key, offset: UInt64(partialSize))
        }
    }

    func begin(_ descriptor: ResourceDescriptor, metadata: AssetMetadata, size: UInt64) throws {
        if let previous = inFlight.removeValue(forKey: descriptor.key) { try? previous.handle.close() }
        let url = partialURL(for: descriptor.key)
        try prepareStateDirectory()
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        inFlight[descriptor.key] = InFlight(descriptor: descriptor, metadata: metadata, size: size, url: url, handle: handle)
    }

    func append(_ data: Data, to key: ResourceKey, at offset: UInt64) throws {
        guard let file = inFlight[key] else { throw StoreError.notStarted(key) }
        // The phone resumes from the offset we asked for; drop anything past it.
        if try file.handle.seekToEnd() != offset {
            try file.handle.truncate(atOffset: offset)
            try file.handle.seek(toOffset: offset)
        }
        try file.handle.write(contentsOf: data)
    }

    /// Verifies the finished file and moves it into the library. Returns its path relative to `root`.
    @discardableResult
    func finish(_ key: ResourceKey, sha256 expected: String) throws -> String {
        guard let file = inFlight.removeValue(forKey: key) else { throw StoreError.notStarted(key) }
        try file.handle.close()

        let size = UInt64((try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size == file.size else {
            try? fileManager.removeItem(at: file.url)
            throw StoreError.sizeMismatch(key, expected: file.size, actual: size)
        }
        let actual = try FileHasher.sha256(of: file.url)
        guard actual == expected else {
            // Usually a resumed edit that iOS re-rendered differently; start over next time.
            try? fileManager.removeItem(at: file.url)
            throw StoreError.checksumMismatch(key)
        }

        // An asset moved into a folder of the library keeps its new files with it.
        var planned = layout.relativePath(for: file.descriptor, of: file.metadata)
        if let sidecar = index.assets[key.assetID]?.sidecar {
            let directory = (sidecar as NSString).deletingLastPathComponent
            planned = directory + "/" + (planned as NSString).lastPathComponent
        }
        let relativePath = uniquePath(planned, sha256: actual)
        let destination = root.appending(path: relativePath)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: file.url)   // identical file already there
        } else {
            try fileManager.moveItem(at: file.url, to: destination)
        }
        if let date = file.metadata.creationDate {
            try? fileManager.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: destination.path)
        }

        let sidecar = try writeSidecar(for: file.metadata, file: .init(
            kind: key.kind, revision: key.revision, name: destination.lastPathComponent, sha256: actual, size: size
        ))
        index.assets[key.assetID] = AssetRecord(metadata: file.metadata, sidecar: sidecar)
        index.resources[key.description] = StoredResource(
            assetID: key.assetID, relativePath: relativePath, sha256: actual, size: size, storedAt: .now
        )
        unsavedChanges += 1
        // The whole index is written each time (13 MB for a big library), so during a backup it's
        // written every 50 files at most twice a minute; the rest when the session ends (`flush`).
        // Files that arrived after the last write are still on the drive if Imago quits meanwhile:
        // the next backup asks for them again and finds them already there.
        if unsavedChanges >= 50, ContinuousClock.now - lastIndexSave > .seconds(30) { try saveIndex() }
        return relativePath
    }

    func recordBackup(deviceID: String) {
        index.lastBackupByDevice[deviceID] = .now
        unsavedChanges += 1
    }

    /// Closes open partial files and writes the index. Call when a session ends.
    /// Saves the index if anything changed since it was last saved.
    func saveIndexIfChanged() {
        if unsavedChanges > 0 { try? saveIndex() }
    }

    func flush() {
        for file in inFlight.values { try? file.handle.close() }
        inFlight.removeAll()
        if unsavedChanges > 0 { try? saveIndex() }
    }

    // MARK: Reading

    func summary() -> Summary {
        var summary = Summary()
        summary.fileCount = index.resources.count
        summary.assetCount = Set(index.resources.values.map(\.assetID)).count
        summary.totalBytes = index.resources.values.reduce(0) { $0 + $1.size }
        summary.lastBackup = index.lastBackupByDevice.values.max()
        summary.lastReceived = index.resources.values.map(\.storedAt).filter { $0 != .distantPast }.max()
        return summary
    }

    /// The file an asset shows as, where it is now (see `CatalogEntry.display`).
    func displayFile(of assetID: String) -> URL? {
        let files = (resourcesByAsset(only: [assetID])[assetID] ?? []).compactMap { key -> (kind: ResourceKind, url: URL)? in
            guard let stored = index.resources[key], let kind = Self.kind(of: key, assetID: assetID) else { return nil }
            return (kind, url(of: stored.relativePath))
        }
        return (files.first { $0.kind == .photo || $0.kind == .video } ?? files.first { $0.kind == .fullSizePhoto || $0.kind == .fullSizeVideo })?.url
    }

    /// How many files are stored: with the library list's date, tells whether `phoneLibrary()` would
    /// come out the same as last time.
    func resourceCount() -> Int {
        index.resources.count
    }

    /// Every stored file, keyed by `ResourceKey.description`.
    func storedResources() -> [String: StoredResource] {
        index.resources
    }

    /// The file each asset shows in the grids, with the asset's total size (what the grids key their
    /// thumbnails by), for assets with a file stored since `date`. Newest first.
    func displayFiles(storedSince date: Date, limit: Int) -> [(url: URL, bytes: UInt64)] {
        resourcesByAsset().compactMap { assetID, keys -> (url: URL, bytes: UInt64, storedAt: Date)? in
            let files = keys.compactMap { key in index.resources[key].map { (kind: Self.kind(of: key, assetID: assetID), stored: $0) } }
            guard let newest = files.map(\.stored.storedAt).max(), newest >= date,
                  let display = files.first(where: { $0.kind == .photo || $0.kind == .video })
                    ?? files.first(where: { $0.kind == .fullSizePhoto || $0.kind == .fullSizeVideo }) else { return nil }
            return (url(of: display.stored.relativePath), files.reduce(0) { $0 + $1.stored.size }, newest)
        }
        .sorted { $0.storedAt > $1.storedAt }
        .prefix(limit)
        .map { ($0.url, $0.bytes) }
    }

    func recentFiles(limit: Int) -> [URL] {
        index.resources.values
            .filter { !$0.relativePath.hasSuffix(".plist") }
            .sorted { $0.storedAt > $1.storedAt }
            .prefix(limit)
            .map { root.appending(path: $0.relativePath) }
    }

    /// Recreates the index by reading every sidecar: this phone's folder, and its assets that were
    /// moved elsewhere in the library (Folders, Recently Deleted). Elsewhere, only sidecars that name
    /// this phone count, so other phones' assets are left to them.
    func rebuildIndex() throws {
        var rebuilt = Index()
        rebuilt.lastBackupByDevice = index.lastBackupByDevice
        let library = root.deletingLastPathComponent()
        for (top, ownedWithoutID) in [(root, true), (library, false)] {
            // Not .skipsHiddenFiles: sidecars are hidden. Dot-files and folders (.photobackup, ._ files)
            // are left out by name.
            let enumerator = fileManager.enumerator(at: top, includingPropertiesForKeys: nil, options: [])
            while let url = enumerator?.nextObject() as? URL {
                if url.lastPathComponent.hasPrefix(".") {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator?.skipDescendants() }
                    continue
                }
                guard url.pathExtension == "json", let sidecar = Self.readSidecar(at: url),
                      sidecar.deviceID.map({ $0 == deviceID }) ?? ownedWithoutID else { continue }
                let folder = relativePath(of: url.deletingLastPathComponent())
                for file in sidecar.files {
                    let key = ResourceKey(assetID: sidecar.metadata.assetID, kind: file.kind, revision: file.revision)
                    rebuilt.resources[key.description] = StoredResource(
                        assetID: key.assetID, relativePath: folder.isEmpty ? file.name : "\(folder)/\(file.name)",
                        sha256: file.sha256, size: file.size, storedAt: .distantPast
                    )
                }
                rebuilt.assets[sidecar.metadata.assetID] = AssetRecord(metadata: sidecar.metadata, sidecar: relativePath(of: url))
            }
        }
        index = rebuilt
        try saveIndex()
    }

    // MARK: Browsing and organizing

    /// Every asset with files here, wherever in the library its files have been moved.
    func catalog() -> [CatalogEntry] {
        if let catalogCache, catalogCache.version == indexVersion { return catalogCache.entries }
        let byAsset = resourcesByAsset()
        fillMissingRecords(byAsset)
        let entries = byAsset.compactMap { assetID, keys -> CatalogEntry? in
            guard let metadata = index.assets[assetID]?.metadata else { return nil }
            let files = keys.compactMap { key -> CatalogEntry.File? in
                guard let stored = index.resources[key], let kind = Self.kind(of: key, assetID: assetID) else { return nil }
                return .init(kind: kind, url: url(of: stored.relativePath), size: stored.size, sha256: stored.sha256)
            }
            return CatalogEntry(assetID: assetID, metadata: metadata, files: files)
        }
        catalogCache = (indexVersion, entries)
        return entries
    }

    /// The catalog, and the version of the index it came from: the same version, the same catalog.
    func versionedCatalog() -> (version: Int, entries: [CatalogEntry]) {
        let entries = catalog()
        return (indexVersion, entries)
    }

    /// Moves assets' files and sidecars into `directory`, or back into the dated folders when it's nil.
    /// The index follows them, so the phone isn't asked for them again.
    /// With `saving` off, the index is saved later (`saveIndexIfChanged`): saving it after every item
    /// of a big move would take longer than the moves. The index is read once for the whole move;
    /// `progress` hears each asset's name as it's done.
    /// Returns where each moved asset's photo or video is now, and what stopped it, if anything did.
    func move(_ assetIDs: [String], to directory: URL?, saving: Bool = true,
              progress: (@Sendable (String) -> Void)? = nil) -> (moved: [String: URL?], error: Error?) {
        let byAsset = resourcesByAsset(only: Set(assetIDs))
        defer { if saving { try? saveIndex() } else { unsavedChanges += 1 } }
        // Two assets can share one file (the iPhone had the same video twice, and the backup kept one
        // copy). A file another asset still uses is copied, not moved, so that asset keeps its file.
        var users: [URL: Int] = [:]
        for stored in index.resources.values { users[url(of: stored.relativePath), default: 0] += 1 }
        var moved: [String: URL?] = [:]
        // In the order asked, so the progress follows the selection.
        for assetID in assetIDs {
            guard let keys = byAsset[assetID], let metadata = index.assets[assetID]?.metadata else { continue }
            let target = directory.map(relativePath(of:))
                ?? (layout.sidecarPath(for: metadata) as NSString).deletingLastPathComponent
            do {
                for key in keys {
                    guard let stored = index.resources[key] else { continue }
                    let source = url(of: stored.relativePath)
                    let wanted = target + "/" + source.lastPathComponent
                    guard url(of: wanted) != source else { continue }
                    let shared = users[source, default: 0] > 1
                    let path = uniquePath(wanted, sha256: stored.sha256) { users[$0, default: 0] > 0 }
                    let destination = url(of: path)
                    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fileManager.fileExists(atPath: destination.path) {
                        // An identical file nothing else uses is already there.
                        if !shared, fileManager.fileExists(atPath: source.path) { try fileManager.removeItem(at: source) }
                    } else if !fileManager.fileExists(atPath: source.path) {
                        // Its file left with an asset it shared it with (an earlier move): copy that one.
                        guard let twin = index.resources.values.lazy.filter({ $0.sha256 == stored.sha256 }).map({ self.url(of: $0.relativePath) })
                            .first(where: { $0 != source && self.fileManager.fileExists(atPath: $0.path) })
                        else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path]) }
                        try fileManager.copyItem(at: twin, to: destination)
                    } else if shared {
                        try fileManager.copyItem(at: source, to: destination)
                    } else {
                        try fileManager.moveItem(at: source, to: destination)
                    }
                    users[source, default: 1] -= 1
                    users[destination, default: 0] += 1
                    index.resources[key]?.relativePath = path
                }
                try settleSidecar(of: assetID, keys: keys, in: target)
            } catch {
                return (moved, error)
            }
            let files = keys.compactMap { key -> (kind: ResourceKind, url: URL)? in
                guard let stored = index.resources[key], let kind = Self.kind(of: key, assetID: assetID) else { return nil }
                return (kind, url(of: stored.relativePath))
            }
            moved[assetID] = .some((files.first { $0.kind == .photo || $0.kind == .video }
                              ?? files.first { $0.kind == .fullSizePhoto || $0.kind == .fullSizeVideo })?.url)
            progress?(metadata.originalFilename)
        }
        return (moved, nil)
    }

    /// Deletes assets' files and sidecars for good (Recently Deleted › Delete Now), and stops asking
    /// the phone for them.
    func deletePermanently(_ assetIDs: [String]) throws {
        let byAsset = resourcesByAsset(only: Set(assetIDs))
        defer {
            try? saveIndex()
            try? prepareStateDirectory()
            try? JSONEncoder().encode(skipped).write(to: skipURL, options: .atomic)
        }
        // A file another asset shares (the same video twice on the iPhone) stays for that asset.
        let leaving = Set(byAsset.values.joined())
        let kept = Set(index.resources.filter { !leaving.contains($0.key) }.map { url(of: $0.value.relativePath) })
        for (assetID, keys) in byAsset {
            let sidecar = index.assets[assetID]?.sidecar ?? locateSidecar(of: assetID, keys: keys)
            for key in keys {
                guard let stored = index.resources[key] else { continue }
                let file = url(of: stored.relativePath)
                if !kept.contains(file), fileManager.fileExists(atPath: file.path) { try fileManager.removeItem(at: file) }
                index.resources[key] = nil
                skipped.insert(key)
            }
            if let sidecar { try? fileManager.removeItem(at: root.appending(path: sidecar)) }
            index.assets[assetID] = nil
        }
    }

    /// Each asset's stored files and the checksum each had when it arrived, to check them again
    /// before the phone is asked to delete its copy.
    func storedFiles(of assetIDs: [String]) -> [String: [(url: URL, sha256: String)]] {
        resourcesByAsset(only: Set(assetIDs)).mapValues { keys in
            keys.compactMap { index.resources[$0].map { (url(of: $0.relativePath), $0.sha256) } }
        }
    }

    /// Files moved in Finder: for each of `urls` that this iPhone's index lost (same name and size,
    /// its old place empty, the same contents), the index follows it there. The index is read once
    /// for them all. Returns the files it took.
    func relink(_ urls: [URL]) -> Set<URL> {
        // Each library read asks about the same files. Unless the index changed since, a file asked
        // about before has the same answer: only new ones are looked at.
        if relinkCache?.version != indexVersion {
            var byName: [String: [String]] = [:]
            for (key, stored) in index.resources { byName[(stored.relativePath as NSString).lastPathComponent, default: []].append(key) }
            relinkCache = (indexVersion, byName, [])
        }
        let fresh = urls.filter { !(relinkCache?.checked.contains($0) ?? false) }
        guard !fresh.isEmpty, let byName = relinkCache?.byName else { return [] }
        relinkCache?.checked.formUnion(fresh)
        var claimed: Set<URL> = []
        for url in fresh {
            guard let keys = byName[url.lastPathComponent] else { continue }
            let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
            guard let key = keys.first(where: { index.resources[$0]?.size == size }), let stored = index.resources[key],
                  !fileManager.fileExists(atPath: self.url(of: stored.relativePath).path),
                  (try? FileHasher.sha256(of: url)) == stored.sha256
            else { continue }
            index.resources[key]?.relativePath = relativePath(of: url)
            let assetKeys = resourcesByAsset(only: [stored.assetID])[stored.assetID] ?? []
            let directories = Set(assetKeys.compactMap { index.resources[$0].map { (self.url(of: $0.relativePath).path as NSString).deletingLastPathComponent } })
            // Bring the sidecar along once all of the asset's files are together.
            if directories.count == 1, let directory = directories.first {
                try? settleSidecar(of: stored.assetID, keys: assetKeys, in: relativePath(of: URL(filePath: directory, directoryHint: .isDirectory)))
            }
            claimed.insert(url)
        }
        if !claimed.isEmpty { try? saveIndex() }
        return claimed
    }

    /// Points the index at a Folder's new place after it was renamed.
    func folderMoved(from old: URL, to new: URL) {
        let oldPrefix = relativePath(of: old) + "/"
        let newPrefix = relativePath(of: new) + "/"
        var changed = false
        for (key, stored) in index.resources where stored.relativePath.hasPrefix(oldPrefix) {
            index.resources[key]?.relativePath = newPrefix + stored.relativePath.dropFirst(oldPrefix.count)
            changed = true
        }
        for (assetID, record) in index.assets {
            if let sidecar = record.sidecar, sidecar.hasPrefix(oldPrefix) {
                index.assets[assetID]?.sidecar = newPrefix + sidecar.dropFirst(oldPrefix.count)
            }
        }
        if changed { try? saveIndex() }
    }

    // MARK: Putting back on the phone

    /// The kinds of file sent back to put an asset back on its phone: its originals. An edit would need
    /// PhotoKit's adjustment format, so the phone gets the photo as it was taken.
    static let restorableKinds: [ResourceKind] = [.photo, .video, .pairedVideo, .alternatePhoto]

    /// What to send to put these assets back on the phone: each one's details and original files, in
    /// order. Assets with no original here are left out.
    func restoreAssets(_ assetIDs: [String]) -> [(asset: RestoreAsset, urls: [URL])] {
        let byAsset = resourcesByAsset(only: Set(assetIDs))
        return assetIDs.compactMap { assetID in
            guard let metadata = index.assets[assetID]?.metadata, let keys = byAsset[assetID] else { return nil }
            let base = (metadata.originalFilename as NSString).deletingPathExtension
            var files: [(RestoreAsset.File, URL)] = []
            for kind in Self.restorableKinds {
                guard let key = keys.first(where: { Self.kind(of: $0, assetID: assetID) == kind && $0.hasSuffix("@original") }),
                      let stored = index.resources[key] else { continue }
                let url = url(of: stored.relativePath)
                // The name it had on the phone: IMG_4821.HEIC, and IMG_4821.MOV for its motion.
                let name = kind == .photo || kind == .video ? metadata.originalFilename : base + "." + url.pathExtension
                files.append((RestoreAsset.File(key: ResourceKey(assetID: assetID, kind: kind, revision: "original"),
                                                originalFilename: name, size: stored.size, sha256: stored.sha256), url))
            }
            guard files.contains(where: { $0.0.key.kind == .photo || $0.0.key.kind == .video }) else { return nil }
            return (RestoreAsset(metadata: metadata, files: files.map(\.0)), files.map(\.1))
        }
    }

    /// Takes a file on the drive that this phone doesn't have (an edited copy beside its original, a
    /// file from Finder) as one of its assets, under an ID of the Mac's own, so it goes to the phone the
    /// way a put-back does. The phone's answer gives it the ID Photos made (`rekey`), and its next
    /// backup finds the file stored. The file stays where it is. Returns the ID.
    func adopt(_ file: URL, metadata: AssetMetadata, kind: ResourceKind) throws -> String {
        let path = relativePath(of: file)
        // Already one of its assets (sent before, or on its way): never twice.
        if let existing = index.resources.values.first(where: { url(of: $0.relativePath) == url(of: path) }) {
            throw AdoptError.alreadyThere(existing.assetID)
        }
        let assetID = "mac-" + UUID().uuidString
        var metadata = metadata
        metadata.assetID = assetID
        let sha256 = try FileHasher.sha256(of: file)
        let size = UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let key = ResourceKey(assetID: assetID, kind: kind, revision: "original").description
        index.assets[assetID] = AssetRecord(metadata: metadata, sidecar: nil)
        index.resources[key] = StoredResource(assetID: assetID, relativePath: path, sha256: sha256, size: size, storedAt: .now)
        try settleSidecar(of: assetID, keys: [key], in: (path as NSString).deletingLastPathComponent)
        try saveIndex()
        return assetID
    }

    /// Whether a file is one of this iPhone's stored files.
    func holds(_ file: URL) -> Bool {
        let path = relativePath(of: file)
        return index.resources.values.contains { url(of: $0.relativePath) == url(of: path) }
    }

    enum AdoptError: LocalizedError {
        case alreadyThere(String)
        var errorDescription: String? { "It's already on its way to the iPhone, or on it." }
    }

    /// Takes assets out of the index without touching their files: copies of one file that went to
    /// the phone more than once. Their sidecars go.
    func forget(_ assetIDs: Set<String>) throws {
        for assetID in assetIDs {
            if let sidecar = index.assets[assetID]?.sidecar { try? fileManager.removeItem(at: root.appending(path: sidecar)) }
            index.assets[assetID] = nil
            for (key, stored) in index.resources where stored.assetID == assetID { index.resources[key] = nil }
        }
        try saveIndex()
    }

    /// The phone couldn't add an adopted file: it's a plain file on the drive again, as before `adopt`.
    func unadopt(_ assetIDs: Set<String>) throws {
        for assetID in assetIDs where assetID.hasPrefix("mac-") {
            if let sidecar = index.assets[assetID]?.sidecar { try? fileManager.removeItem(at: root.appending(path: sidecar)) }
            index.assets[assetID] = nil
            for (key, stored) in index.resources where stored.assetID == assetID { index.resources[key] = nil }
        }
        try saveIndex()
    }

    /// The phone put assets back under new IDs (old → new): their files, records and sidecars take the
    /// new ID, so the phone's next backup finds them stored and doesn't send them again.
    func rekey(_ ids: [String: String]) throws {
        let byAsset = resourcesByAsset(only: Set(ids.keys))
        defer { try? saveIndex() }
        for (old, new) in ids where old != new {
            for key in byAsset[old] ?? [] {
                guard var stored = index.resources.removeValue(forKey: key) else { continue }
                stored.assetID = new
                index.resources[new + key.dropFirst(old.count)] = stored
            }
            guard var record = index.assets.removeValue(forKey: old) else { continue }
            record.metadata.assetID = new
            if let path = record.sidecar ?? locateSidecar(of: old, keys: byAsset[old] ?? []),
               var sidecar = Self.readSidecar(at: url(of: path)) {
                sidecar.metadata.assetID = new
                try Self.write(sidecar, to: url(of: path))
                record.sidecar = path
            }
            index.assets[new] = record
        }
    }

    /// An asset as a library-list entry with the files it has here, for the saved list after it's put
    /// back on the phone (until the phone's next backup sends a fresh list).
    func manifestEntry(of assetID: String) -> ManifestEntry? {
        guard let metadata = index.assets[assetID]?.metadata else { return nil }
        let resources = (resourcesByAsset(only: [assetID])[assetID] ?? []).compactMap { key -> ResourceDescriptor? in
            guard let kind = Self.kind(of: key, assetID: assetID), Self.restorableKinds.contains(kind), key.hasSuffix("@original") else { return nil }
            return ResourceDescriptor(key: ResourceKey(assetID: assetID, kind: kind, revision: "original"),
                                      originalFilename: metadata.originalFilename, uti: "")
        }
        return resources.isEmpty ? nil : ManifestEntry(metadata: metadata, resources: resources)
    }

    /// Writes the asset's sidecar into `directory` (relative to `root`), naming its files as they are
    /// now, and removes the old one.
    private func settleSidecar(of assetID: String, keys: [String], in directory: String) throws {
        guard var record = index.assets[assetID] else { return }
        let old = (record.sidecar ?? locateSidecar(of: assetID, keys: keys)).map { root.appending(path: $0) }
        var sidecar = old.flatMap(Self.readSidecar) ?? Sidecar(metadata: record.metadata, files: [])
        sidecar.deviceID = deviceID
        for key in keys {
            guard let stored = index.resources[key], let kind = Self.kind(of: key, assetID: assetID) else { continue }
            let revision = String(key.dropFirst(assetID.count + 1 + kind.rawValue.count + 1))
            let file = Sidecar.File(kind: kind, revision: revision, name: url(of: stored.relativePath).lastPathComponent,
                                    sha256: stored.sha256, size: stored.size)
            if let i = sidecar.files.firstIndex(where: { $0.kind == kind && $0.revision == revision }) {
                sidecar.files[i] = file
            } else if !sidecar.files.contains(where: { $0.kind == kind }) {
                sidecar.files.append(file)
            }
        }

        // Keep the sidecar's own name; it may be numbered past another asset's.
        let name = old?.lastPathComponent ?? (layout.sidecarPath(for: record.metadata) as NSString).lastPathComponent
        let base = directory + "/" + name
        var path = base
        var n = 2
        while url(of: path) != old?.lexicallyStandardized, fileManager.fileExists(atPath: url(of: path).path),
              Self.readSidecar(at: url(of: path))?.metadata.assetID != assetID {
            path = LibraryLayout.numbered(base, n)
            n += 1
        }
        let destination = url(of: path)
        try Self.write(sidecar, to: destination)
        if let old, old.lexicallyStandardized != destination { try? fileManager.removeItem(at: old) }
        record.sidecar = path
        index.assets[assetID] = record
    }

    /// Index keys of each asset's files.
    private func resourcesByAsset(only assetIDs: Set<String>? = nil) -> [String: [String]] {
        var byAsset: [String: [String]] = [:]
        for (key, stored) in index.resources where assetIDs?.contains(stored.assetID) ?? true {
            byAsset[stored.assetID, default: []].append(key)
        }
        return byAsset
    }

    /// Gives every asset a record, for indexes from before records existed: metadata from the phone's
    /// last library list where it's still on the phone, otherwise from the sidecars next to its files.
    private func fillMissingRecords(_ byAsset: [String: [String]]) {
        let missing = byAsset.keys.filter { index.assets[$0] == nil }
        guard !missing.isEmpty else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let snapshot = try? decoder.decode(PhoneSnapshot.self, from: Data(contentsOf: stateDirectory.appending(path: "phone.json"))) {
            let wanted = Set(missing)
            for entry in snapshot.entries where wanted.contains(entry.metadata.assetID) {
                index.assets[entry.metadata.assetID] = AssetRecord(metadata: entry.metadata)
            }
        }

        var directories: Set<String> = []
        for assetID in missing where index.assets[assetID] == nil {
            for key in byAsset[assetID] ?? [] {
                if let path = index.resources[key]?.relativePath { directories.insert((path as NSString).deletingLastPathComponent) }
            }
        }
        for directory in directories {
            for (path, sidecar) in sidecars(in: directory) where index.assets[sidecar.metadata.assetID] == nil {
                index.assets[sidecar.metadata.assetID] = AssetRecord(metadata: sidecar.metadata, sidecar: path)
            }
        }
        unsavedChanges += 1
        try? saveIndex()
    }

    /// Finds the asset's sidecar among the sidecars next to its files.
    private func locateSidecar(of assetID: String, keys: [String]) -> String? {
        let directories = Set(keys.compactMap { index.resources[$0].map { ($0.relativePath as NSString).deletingLastPathComponent } })
        for directory in directories {
            if let match = sidecars(in: directory).first(where: { $0.1.metadata.assetID == assetID }) { return match.0 }
        }
        return nil
    }

    /// The sidecars in a folder, with their paths relative to `root`.
    private func sidecars(in directory: String) -> [(String, Sidecar)] {
        let names = (try? fileManager.contentsOfDirectory(atPath: url(of: directory).path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            let path = directory + "/" + name
            return Self.readSidecar(at: url(of: path)).map { (path, $0) }
        }
    }

    /// A path in the index as a URL. Paths may start with "../" for files moved out of this phone's
    /// folder into another part of the library.
    nonisolated func url(of relativePath: String) -> URL {
        root.appending(path: relativePath).lexicallyStandardized
    }

    /// `url` as a path relative to `root`, using "../" for places outside it.
    private nonisolated func relativePath(of url: URL) -> String {
        let base = root.lexicallyStandardized.pathComponents
        let target = url.lexicallyStandardized.pathComponents
        var common = 0
        while common < min(base.count, target.count), base[common] == target[common] { common += 1 }
        return (Array(repeating: "..", count: base.count - common) + target[common...]).joined(separator: "/")
    }

    /// The kind in an index key, "assetID#kind@revision".
    private static func kind(of key: String, assetID: String) -> ResourceKind? {
        let rest = key.dropFirst(assetID.count + 1)
        return rest.firstIndex(of: "@").flatMap { ResourceKind(rawValue: String(rest[..<$0])) }
    }

    // MARK: Helpers

    private func partialURL(for key: ResourceKey) -> URL {
        partialDirectory.appending(path: FileHasher.sha256(of: Data(key.description.utf8)) + ".part")
    }

    /// Picks "name (2).ext" if a different file already has this name.
    /// `taken`: a file there that's identical but already some asset's doesn't count as free.
    private func uniquePath(_ path: String, sha256: String, taken: (URL) -> Bool = { _ in false }) -> String {
        var candidate = path
        var n = 2
        while fileManager.fileExists(atPath: root.appending(path: candidate).path),
              taken(url(of: candidate)) || (try? FileHasher.sha256(of: root.appending(path: candidate))) != sha256 {
            candidate = LibraryLayout.numbered(path, n)
            n += 1
        }
        return candidate
    }

    /// Adds `file` to the asset's sidecar and returns the sidecar's path relative to `root`.
    private func writeSidecar(for metadata: AssetMetadata, file: Sidecar.File) throws -> String {
        let path: String
        if let recorded = index.assets[metadata.assetID]?.sidecar, fileManager.fileExists(atPath: root.appending(path: recorded).path) {
            path = recorded
        } else {
            path = layout.sidecarPath(for: metadata) { path in
                let url = root.appending(path: path)
                return !fileManager.fileExists(atPath: url.path) || Self.readSidecar(at: url)?.metadata.assetID == metadata.assetID
            }
        }
        let url = root.appending(path: path)
        var sidecar = Self.readSidecar(at: url) ?? Sidecar(metadata: metadata, files: [])
        sidecar.metadata = metadata
        sidecar.deviceID = deviceID
        sidecar.upsert(file)
        try Self.write(sidecar, to: url)
        return path
    }

    private static func write(_ sidecar: Sidecar, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(sidecar).write(to: url, options: .atomic)
        hide(url)
    }

    /// Sidecars are hidden in Finder (the hidden flag, not a name change): they're for Imago, and
    /// cluttered every folder. They keep their names, so the layout and other tools are unchanged.
    private static func hide(_ url: URL) {
        var file = url
        var values = URLResourceValues()
        values.isHidden = true
        try? file.setResourceValues(values)
    }

    /// Hides the sidecars written before they were hidden, once per phone folder.
    func hideOlderSidecars() {
        let marker = stateDirectory.appending(path: "sidecars-hidden")
        guard !fileManager.fileExists(atPath: marker.path) else { return }
        for record in index.assets.values {
            guard let sidecar = record.sidecar else { continue }
            Self.hide(root.appending(path: sidecar))
        }
        try? prepareStateDirectory()
        fileManager.createFile(atPath: marker.path, contents: nil)
    }

    private static func readSidecar(at url: URL) -> Sidecar? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Sidecar.self, from: Data(contentsOf: url))
    }

    private func saveIndex() throws {
        try prepareStateDirectory()
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
        unsavedChanges = 0
        lastIndexSave = .now
    }
}
