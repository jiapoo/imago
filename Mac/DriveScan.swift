import Foundation
import UniformTypeIdentifiers

/// Lists what's in folders on the backup drive, quickly when little has changed there.
///
/// A folder's modification date changes whenever something in it is added, removed or renamed, so a
/// folder whose date is what it was last time is taken from memory without listing it again: a scan
/// looks at each folder's date, and lists only the folders that changed. Walking every file of every
/// iPhone's backups instead takes half a minute on a USB drive. The listings are kept in Caches too,
/// so the first scan after launch is quick as well.
nonisolated final class DriveScan: @unchecked Sendable {
    static let shared = DriveScan()

    private struct Listing: Codable {
        var modified: Date
        /// Names of the photos and videos in the folder.
        var media: [String]
        /// Names of the folders in it (not packages).
        var folders: [String]
    }

    private let lock = NSLock()
    private var listings: [String: Listing]?
    private var changed = false

    private var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: Bundle.main.bundleIdentifier ?? "Imago", directoryHint: .isDirectory)
            .appending(path: "drive-scan.plist")
    }

    /// The photos and videos anywhere under `directory`, leaving out hidden files and what's inside packages.
    func mediaFiles(in directory: URL) -> [URL] {
        var found: [URL] = []
        walk(directory.lexicallyStandardized) { folder, listing in
            found += listing.media.map { folder.appending(path: $0) }
        }
        return found
    }

    /// The folders under `directory`, as paths from it ("Trips", "Trips/Rome").
    func folders(in directory: URL) -> [String] {
        let base = directory.lexicallyStandardized
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        var paths: [String] = []
        walk(base) { folder, _ in
            if folder.path.count > prefix.count { paths.append(String(folder.path.dropFirst(prefix.count))) }
        }
        return paths
    }

    /// The names of the folders directly in `directory`.
    func subfolders(of directory: URL) -> [String] {
        listing(of: directory.lexicallyStandardized)?.folders ?? []
    }

    /// Keeps the listings for next launch, if any changed. Call after a scan.
    func save() {
        let snapshot: [String: Listing]? = lock.withLock {
            guard changed else { return nil }
            changed = false
            return listings
        }
        guard let snapshot, let data = try? PropertyListEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func walk(_ folder: URL, _ visit: (URL, Listing) -> Void) {
        guard let listing = listing(of: folder) else { return }
        visit(folder, listing)
        for name in listing.folders { walk(folder.appending(path: name, directoryHint: .isDirectory), visit) }
    }

    /// The folder's listing: from memory when the folder hasn't changed since, otherwise read again.
    private func listing(of folder: URL) -> Listing? {
        guard let modified = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        let key = folder.path
        let cached = lock.withLock { () -> Listing? in
            if listings == nil { listings = Self.read(from: cacheURL) }
            return listings?[key]
        }
        if let cached, cached.modified == modified { return cached }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isRegularFileKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }
        var listing = Listing(modified: modified, media: [], folders: [])
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if values.isPackage != true { listing.folders.append(url.lastPathComponent) }
            } else if values.isRegularFile == true, Self.isMedia(url) {
                listing.media.append(url.lastPathComponent)
            }
        }
        lock.withLock {
            listings?[key] = listing
            changed = true
        }
        return listing
    }

    private static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    private static func read(from url: URL) -> [String: Listing] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? PropertyListDecoder().decode([String: Listing].self, from: data)) ?? [:]
    }
}
