import Foundation
import PhotoBackupKit

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
    private var index: Index
    private var inFlight: [ResourceKey: InFlight] = [:]
    private var unsavedChanges = 0
    private let fileManager = FileManager.default

    nonisolated var stateDirectory: URL { root.appending(path: ".photobackup", directoryHint: .isDirectory) }
    private nonisolated var partialDirectory: URL { stateDirectory.appending(path: "partial", directoryHint: .isDirectory) }
    private nonisolated var indexURL: URL { stateDirectory.appending(path: "index.json") }
    private nonisolated var skipURL: URL { stateDirectory.appending(path: "skip.json") }
    /// Files moved to the Trash on the Mac, by key. The phone isn't asked for them again.
    private var skipped: Set<String>

    init(root: URL, deviceID: String) {
        self.root = root
        self.deviceID = deviceID
        try? FileManager.default.createDirectory(
            at: root.appending(path: ".photobackup/partial", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let indexURL = root.appending(path: ".photobackup/index.json")
        index = (try? JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))) ?? Index()
        skipped = (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: root.appending(path: ".photobackup/skip.json")))) ?? []
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
        if unsavedChanges >= 50 { try saveIndex() }
        return relativePath
    }

    func recordBackup(deviceID: String) {
        index.lastBackupByDevice[deviceID] = .now
        unsavedChanges += 1
    }

    /// Closes open partial files and writes the index. Call when a session ends.
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

    /// Every stored file, keyed by `ResourceKey.description`.
    func storedResources() -> [String: StoredResource] {
        index.resources
    }

    func recentFiles(limit: Int) -> [URL] {
        index.resources.values
            .filter { !$0.relativePath.hasSuffix(".plist") }
            .sorted { $0.storedAt > $1.storedAt }
            .prefix(limit)
            .map { root.appending(path: $0.relativePath) }
    }

    /// Recreates the index by reading every sidecar: this phone's folder, and its assets that were
    /// moved into the library's Folders.
    func rebuildIndex() throws {
        var rebuilt = Index()
        rebuilt.lastBackupByDevice = index.lastBackupByDevice
        let folders = root.deletingLastPathComponent().appending(path: MediaLibrary.foldersName, directoryHint: .isDirectory)
        for (top, ownedWithoutID) in [(root, true), (folders, false)] {
            let enumerator = fileManager.enumerator(at: top, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            while let url = enumerator?.nextObject() as? URL {
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
        let byAsset = resourcesByAsset()
        fillMissingRecords(byAsset)
        return byAsset.compactMap { assetID, keys in
            guard let metadata = index.assets[assetID]?.metadata else { return nil }
            let files = keys.compactMap { key -> CatalogEntry.File? in
                guard let stored = index.resources[key], let kind = Self.kind(of: key, assetID: assetID) else { return nil }
                return .init(kind: kind, url: url(of: stored.relativePath), size: stored.size)
            }
            return CatalogEntry(assetID: assetID, metadata: metadata, files: files)
        }
    }

    /// Moves assets' files and sidecars into `directory`, or back into the dated folders when it's nil.
    /// The index follows them, so the phone isn't asked for them again.
    func move(_ assetIDs: [String], to directory: URL?) throws {
        let byAsset = resourcesByAsset(only: Set(assetIDs))
        defer { try? saveIndex() }
        for (assetID, keys) in byAsset {
            guard let metadata = index.assets[assetID]?.metadata else { continue }
            let target = directory.map(relativePath(of:))
                ?? (layout.sidecarPath(for: metadata) as NSString).deletingLastPathComponent
            for key in keys {
                guard let stored = index.resources[key] else { continue }
                let source = url(of: stored.relativePath)
                let wanted = target + "/" + source.lastPathComponent
                guard url(of: wanted) != source else { continue }
                let path = uniquePath(wanted, sha256: stored.sha256)
                let destination = root.appending(path: path)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: source)   // identical file already there
                } else {
                    try fileManager.moveItem(at: source, to: destination)
                }
                index.resources[key]?.relativePath = path
            }
            try settleSidecar(of: assetID, keys: keys, in: target)
        }
    }

    /// Moves assets' files and sidecars to the Trash, and stops asking the phone for them.
    func trash(_ assetIDs: [String]) throws {
        let byAsset = resourcesByAsset(only: Set(assetIDs))
        defer {
            try? saveIndex()
            try? JSONEncoder().encode(skipped).write(to: skipURL, options: .atomic)
        }
        for (assetID, keys) in byAsset {
            let sidecar = index.assets[assetID]?.sidecar ?? locateSidecar(of: assetID, keys: keys)
            for key in keys {
                guard let stored = index.resources[key] else { continue }
                let file = url(of: stored.relativePath)
                if fileManager.fileExists(atPath: file.path) { try fileManager.trashItem(at: file, resultingItemURL: nil) }
                index.resources[key] = nil
                skipped.insert(key)
            }
            if let sidecar { try? fileManager.trashItem(at: root.appending(path: sidecar), resultingItemURL: nil) }
            index.assets[assetID] = nil
        }
    }

    /// Takes note of a file that was moved in Finder: if the index's copy of it is gone and `url` has
    /// the same name and size, the index points there instead. Returns whether it did.
    func relink(_ url: URL) throws -> Bool {
        let name = url.lastPathComponent
        let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
        guard let (key, stored) = index.resources.first(where: {
                  ($0.value.relativePath as NSString).lastPathComponent == name && $0.value.size == size
              }).map({ ($0.key, $0.value) }),
              !fileManager.fileExists(atPath: self.url(of: stored.relativePath).path),
              try FileHasher.sha256(of: url) == stored.sha256
        else { return false }
        index.resources[key]?.relativePath = relativePath(of: url)
        let keys = resourcesByAsset(only: [stored.assetID])[stored.assetID] ?? []
        let directories = Set(keys.compactMap { index.resources[$0].map { (self.url(of: $0.relativePath).path as NSString).deletingLastPathComponent } })
        // Bring the sidecar along once all of the asset's files are together.
        if directories.count == 1, let directory = directories.first {
            try settleSidecar(of: stored.assetID, keys: keys, in: relativePath(of: URL(filePath: directory, directoryHint: .isDirectory)))
        }
        try saveIndex()
        return true
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
        while url(of: path) != old?.standardizedFileURL, fileManager.fileExists(atPath: url(of: path).path),
              Self.readSidecar(at: url(of: path))?.metadata.assetID != assetID {
            path = LibraryLayout.numbered(base, n)
            n += 1
        }
        let destination = url(of: path)
        try Self.write(sidecar, to: destination)
        if let old, old.standardizedFileURL != destination { try? fileManager.removeItem(at: old) }
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
        root.appending(path: relativePath).standardizedFileURL
    }

    /// `url` as a path relative to `root`, using "../" for places outside it.
    private nonisolated func relativePath(of url: URL) -> String {
        let base = root.standardizedFileURL.pathComponents
        let target = url.standardizedFileURL.pathComponents
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
    private func uniquePath(_ path: String, sha256: String) -> String {
        var candidate = path
        var n = 2
        while fileManager.fileExists(atPath: root.appending(path: candidate).path),
              (try? FileHasher.sha256(of: root.appending(path: candidate))) != sha256 {
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
    }

    private static func readSidecar(at url: URL) -> Sidecar? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Sidecar.self, from: Data(contentsOf: url))
    }

    private func saveIndex() throws {
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
        unsavedChanges = 0
    }
}
