import CoreServices
import Foundation

/// Hears about changes under a folder on the backup drive, through FSEvents: which folders had
/// something added, removed or renamed in them, a moment after it happened. Changes made outside
/// Imago (Finder, AirDrop, another app) show up in the library from this, folder by folder, without
/// reading the whole library again.
nonisolated final class DriveWatcher: @unchecked Sendable {
    let root: URL
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "Imago.DriveWatcher")
    private let changed: @Sendable (_ folders: [URL], _ scanBelow: Bool) -> Void
    /// FSEvents names folders by their real path (/private/tmp for /tmp): those are given back under
    /// `root` as it was asked for.
    private let realRoot: String

    /// `changed` hears the folders that changed, on a background queue. `scanBelow`: FSEvents lost
    /// track (too many at once, or the drive came back), so everything under them may have changed.
    init?(root: URL, changed: @escaping @Sendable (_ folders: [URL], _ scanBelow: Bool) -> Void) {
        self.root = root
        self.changed = changed
        // Not `resolvingSymlinksInPath`, which turns /private/tmp back into /tmp.
        realRoot = realpath(root.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? root.path
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DriveWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            var folders: [URL] = []
            var scanBelow = false
            for i in 0..<min(count, paths.count) {
                let flag = Int(flags[i])
                if flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount) != 0 {
                    scanBelow = true
                }
                var path = paths[i]
                if path.hasPrefix(watcher.realRoot), watcher.realRoot != watcher.root.path {
                    path = watcher.root.path + path.dropFirst(watcher.realRoot.count)
                }
                folders.append(URL(filePath: path, directoryHint: .isDirectory))
            }
            watcher.changed(folders, scanBelow)
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    deinit {
        guard let stream else { return }
        // On its queue, so a callback under way finishes before the watcher goes.
        queue.sync {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
        }
        FSEventStreamRelease(stream)
    }
}
