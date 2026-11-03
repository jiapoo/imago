import Foundation
import Synchronization

/// Backed-up files read recently and found to hold what their checksum says, so the check before an
/// iPhone deletes its copy (`MediaLibrary.removeFromPhone`) needn't read them again: reading every
/// byte of big videos was most of a Move's time.
///
/// A file is known by itself, its volume and file number, which a move or rename on the drive keeps,
/// together with its size and date: changed since, it's read again. A check is trusted for 30 days;
/// after that the file is read again, as the check is there to catch a backup gone bad on the drive.
/// Kept in Caches.
nonisolated enum VerifiedFiles {
    private struct Known: Codable {
        var size: UInt64
        var modified: Date
        var sha256: String
        var checkedAt: Date
    }

    private static let trustedFor: TimeInterval = 30 * 86_400
    private static let state = Mutex<(known: [String: Known], changed: Bool)?>(nil)

    private static var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: Bundle.main.bundleIdentifier ?? "Imago", directoryHint: .isDirectory)
            .appending(path: "verified-files.plist")
    }

    /// Whether `url` was found to hold `sha256` recently, unchanged since.
    static func isVerified(_ url: URL, sha256: String) -> Bool {
        guard let (key, size, modified) = identity(of: url) else { return false }
        return withState { state in
            guard let known = state.known[key] else { return false }
            return known.size == size && known.modified == modified && known.sha256 == sha256
                && Date.now.timeIntervalSince(known.checkedAt) < trustedFor
        }
    }

    /// Notes that `url` was just read and holds `sha256`.
    static func note(_ url: URL, sha256: String) {
        guard let (key, size, modified) = identity(of: url) else { return }
        withState { state in
            state.known[key] = Known(size: size, modified: modified, sha256: sha256, checkedAt: .now)
            state.changed = true
        }
    }

    /// Writes what changed to Caches.
    static func save() {
        let known: [String: Known]? = withState { state in
            guard state.changed else { return nil }
            state.changed = false
            // Older than any check still trusted: dropped.
            state.known = state.known.filter { Date.now.timeIntervalSince($0.value.checkedAt) < trustedFor }
            return state.known
        }
        guard let known, let data = try? PropertyListEncoder().encode(known) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func withState<T>(_ body: (inout (known: [String: Known], changed: Bool)) -> T) -> T {
        state.withLock { stored in
            var current = stored ?? ((try? Data(contentsOf: cacheURL)).flatMap { try? PropertyListDecoder().decode([String: Known].self, from: $0) } ?? [:], false)
            defer { stored = current }
            return body(&current)
        }
    }

    /// The file's volume and file number, and its size and date now.
    private static func identity(of url: URL) -> (String, UInt64, Date)? {
        guard let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .fileSizeKey, .contentModificationDateKey]),
              let volume = values.volumeUUIDString, let size = values.fileSize, let modified = values.contentModificationDate,
              let number = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? UInt64
        else { return nil }
        return ("\(volume):\(number)", UInt64(size), modified)
    }
}
