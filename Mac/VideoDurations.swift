import AVFoundation
import Foundation
import Synchronization

/// How long videos are that no iPhone's index describes: edited copies, copies in folders, files from
/// Finder. Each is read once, off the main thread, and kept in Caches by its path, size and date, so a
/// file is read again only when it changes.
enum VideoDurations {
    private struct Known: Codable {
        var size: UInt64
        var modified: Date
        var seconds: Double
    }

    private static let known = Mutex<[String: Known]?>(nil)

    private static var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: Bundle.main.bundleIdentifier ?? "Imago", directoryHint: .isDirectory)
            .appending(path: "video-durations.plist")
    }

    /// The length of each of `urls` that could be read, in seconds.
    static func lengths(of urls: [URL]) async -> [URL: Double] {
        await Task.detached(priority: .utility) {
            var cached = known.withLock { cache in
                if cache == nil {
                    cache = (try? Data(contentsOf: cacheURL)).flatMap { try? PropertyListDecoder().decode([String: Known].self, from: $0) } ?? [:]
                }
                return cache ?? [:]
            }
            var found: [URL: Double] = [:]
            var unread: [(url: URL, size: UInt64, modified: Date)] = []
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = values.fileSize.map(UInt64.init), let modified = values.contentModificationDate else { continue }
                if let entry = cached[url.path], entry.size == size, entry.modified == modified {
                    found[url] = entry.seconds
                } else {
                    unread.append((url, size, modified))
                }
            }
            guard !unread.isEmpty else { return found }
            // A few at a time: each opens the file on what may be a slow drive.
            await withTaskGroup(of: (URL, UInt64, Date, Double?).self) { group in
                var next = 0
                func add() {
                    guard next < unread.count else { return }
                    let file = unread[next]
                    next += 1
                    group.addTask {
                        let seconds = try? await AVURLAsset(url: file.url).load(.duration).seconds
                        return (file.url, file.size, file.modified, seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
                    }
                }
                for _ in 0..<4 { add() }
                while let (url, size, modified, seconds) = await group.next() {
                    if let seconds {
                        found[url] = seconds
                        cached[url.path] = Known(size: size, modified: modified, seconds: seconds)
                    }
                    add()
                }
            }
            known.withLock { $0 = cached }
            if let data = try? PropertyListEncoder().encode(cached) {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
            return found
        }.value
    }
}
