import Foundation
import IOKit.pwr_mgt

/// Keeps the backup drive spinning while a photo page is open.
///
/// The backup drive is often a spinning disk on USB. Left idle (macOS's "put hard disks to sleep",
/// 10 minutes by default, or the drive's own timer) it stops, and the next read waits 10–25 seconds
/// for it to spin up: opening a video then looked stuck. While someone browses, thumbnails come from
/// this Mac's own disk, so nothing else keeps the drive busy. So while a page is open this holds
/// macOS's disk-idle assertion and reads a few kilobytes from the drive every 45 seconds, which also
/// keeps a drive with its own sleep timer awake. Opening a page wakes the drive right away, so it's
/// spinning by the time a video is opened.
@MainActor
final class DriveKeepAwake {
    private var users = 0
    private var assertion: IOPMAssertionID?
    private var task: Task<Void, Never>?

    /// `files` gives some files on the drive to read from; called each time, so it follows the location.
    func begin(files: @escaping @MainActor () async -> [URL]) {
        users += 1
        guard users == 1 else { return }
        var id = IOPMAssertionID(0)
        // kIOPMAssertPreventDiskIdle, a CFSTR macro Swift doesn't import.
        if IOPMAssertionCreateWithName("PreventDiskIdle" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       "Imago is showing photos from the backup drive" as CFString, &id) == kIOReturnSuccess {
            assertion = id
        }
        task = Task {
            while !Task.isCancelled {
                if let file = await files().randomElement() {
                    await Task.detached(priority: .userInitiated) { Self.touch(file) }.value
                }
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    func end() {
        guard users > 0 else { return }
        users -= 1
        guard users == 0 else { return }
        task?.cancel()
        task = nil
        if let assertion { IOPMAssertionRelease(assertion) }
        assertion = nil
    }

    /// Reads 4 KB from a random place in `file`, bypassing the cache so it reaches the drive.
    nonisolated private static func touch(_ file: URL) {
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var info = stat()
        guard fstat(fd, &info) == 0 else { return }
        let blocks = max(Int64(info.st_size) / 4096, 1)
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = pread(fd, &buffer, 4096, off_t(Int64.random(in: 0..<blocks) * 4096))
    }
}
