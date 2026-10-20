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
    private let layout = LibraryLayout()
    private var index: Index
    private var inFlight: [ResourceKey: InFlight] = [:]
    private var unsavedChanges = 0
    private let fileManager = FileManager.default

    nonisolated var stateDirectory: URL { root.appending(path: ".photobackup", directoryHint: .isDirectory) }
    private nonisolated var partialDirectory: URL { stateDirectory.appending(path: "partial", directoryHint: .isDirectory) }
    private nonisolated var indexURL: URL { stateDirectory.appending(path: "index.json") }

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(
            at: root.appending(path: ".photobackup/partial", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let indexURL = root.appending(path: ".photobackup/index.json")
        index = (try? JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))) ?? Index()
    }

    // MARK: Receiving

    /// What the phone should send for this manifest batch, resuming partial files where possible.
    func resumePoints(for manifest: [ManifestEntry]) -> [ResumePoint] {
        manifest.flatMap(\.resources).compactMap { resource in
            guard index.resources[resource.key.description] == nil else { return nil }
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

        let relativePath = uniquePath(layout.relativePath(for: file.descriptor, of: file.metadata), sha256: actual)
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

        try writeSidecar(for: file.metadata, file: .init(
            kind: key.kind, revision: key.revision, name: destination.lastPathComponent, sha256: actual, size: size
        ))
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

    /// Recreates the index by reading every sidecar in the library.
    func rebuildIndex() throws {
        var rebuilt = Index(lastBackupByDevice: index.lastBackupByDevice)
        let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "json",
                  let sidecar = try? decoder.decode(Sidecar.self, from: Data(contentsOf: url)) else { continue }
            let folder = url.deletingLastPathComponent().path.dropFirst(root.path.count + 1)
            for file in sidecar.files {
                let key = ResourceKey(assetID: sidecar.metadata.assetID, kind: file.kind, revision: file.revision)
                rebuilt.resources[key.description] = StoredResource(
                    assetID: key.assetID, relativePath: "\(folder)/\(file.name)",
                    sha256: file.sha256, size: file.size, storedAt: .distantPast
                )
            }
        }
        index = rebuilt
        try saveIndex()
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

    private func writeSidecar(for metadata: AssetMetadata, file: Sidecar.File) throws {
        let path = layout.sidecarPath(for: metadata) { path in
            let url = root.appending(path: path)
            return !fileManager.fileExists(atPath: url.path) || Self.readSidecar(at: url)?.metadata.assetID == metadata.assetID
        }
        let url = root.appending(path: path)
        var sidecar = Self.readSidecar(at: url) ?? Sidecar(metadata: metadata, files: [])
        sidecar.metadata = metadata
        sidecar.upsert(file)

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
