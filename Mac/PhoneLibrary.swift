import Foundation
import PhotoBackupKit

/// What was on the phone at its last backup: every asset with its files, and every album.
/// Saved at the end of each manifest, so the Mac can suggest changes while the phone is away.
struct PhoneSnapshot: Codable {
    var takenAt: Date
    var entries: [ManifestEntry]
    var albums: [String]
}

/// Changes waiting for the phone, and what happened to earlier ones.
struct ChangeQueue: Codable {
    struct Done: Codable, Identifiable {
        var change: LibraryChange
        var report: ChangeReport
        var id: UUID { change.id }
    }

    var pending: [LibraryChange] = []
    var done: [Done] = []
}

/// The phone's library as the Mac sees it, joined with the backup.
struct PhoneLibrary {
    var takenAt: Date
    var assets: [PhoneAsset]
    var albums: [String]
    /// The backed-up original of each asset (the rendered edit if that's all there is), for thumbnails.
    var files: [String: URL]
}

// Kept in the device's `.photobackup` folder, next to the index, so it moves with the backups.
extension BackupStore {
    private nonisolated var snapshotURL: URL { stateDirectory.appending(path: "phone.json") }
    private nonisolated var changesURL: URL { stateDirectory.appending(path: "changes.json") }

    func saveSnapshot(_ snapshot: PhoneSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
    }

    /// The last snapshot joined with what's stored. Nil before the phone's first version-4 backup.
    func phoneLibrary() -> PhoneLibrary? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(PhoneSnapshot.self, from: Data(contentsOf: snapshotURL)) else { return nil }
        let stored = storedResources()

        var files: [String: URL] = [:]
        let assets = snapshot.entries.map { entry in
            let keys = entry.resources.map(\.key)
            let present = keys.compactMap { key in stored[key.description].map { (key: key, file: $0) } }
            let original = present.first { $0.key.kind == .photo || $0.key.kind == .video }
            let display = original ?? present.first { $0.key.kind == .fullSizePhoto || $0.key.kind == .fullSizeVideo }
            if let display { files[entry.metadata.assetID] = root.appending(path: display.file.relativePath) }
            return PhoneAsset(
                metadata: entry.metadata,
                originalSHA256: original?.file.sha256,
                bytes: present.reduce(0) { $0 + $1.file.size },
                isBackedUp: !keys.isEmpty && present.count == keys.count
            )
        }
        return PhoneLibrary(takenAt: snapshot.takenAt, assets: assets, albums: snapshot.albums, files: files)
    }

    func changeQueue() -> ChangeQueue {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ChangeQueue.self, from: Data(contentsOf: changesURL))) ?? ChangeQueue()
    }

    func enqueue(_ change: LibraryChange) throws {
        var queue = changeQueue()
        queue.pending.append(change)
        try save(queue)
    }

    func cancelChange(_ id: UUID) throws {
        var queue = changeQueue()
        queue.pending.removeAll { $0.id == id }
        try save(queue)
    }

    /// Moves reported changes out of the queue. Returns the ones that matched, for the activity log.
    @discardableResult
    func record(_ reports: [ChangeReport]) throws -> [ChangeQueue.Done] {
        var queue = changeQueue()
        var matched: [ChangeQueue.Done] = []
        for report in reports {
            guard let index = queue.pending.firstIndex(where: { $0.id == report.changeID }) else { continue }
            let done = ChangeQueue.Done(change: queue.pending.remove(at: index), report: report)
            queue.done.insert(done, at: 0)
            matched.append(done)
        }
        queue.done = Array(queue.done.prefix(200))
        try save(queue)
        return matched
    }

    private func save(_ queue: ChangeQueue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(queue).write(to: changesURL, options: .atomic)
    }
}
