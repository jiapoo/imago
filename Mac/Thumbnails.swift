import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Makes grid thumbnails and keeps them on the Mac's own disk, so a big library on a slow external
/// drive is only read once. Photos use the preview embedded in the file, which reads a few hundred
/// kilobytes instead of the whole original; videos grab one frame. Only a few files are read from
/// the drive at a time, newest request first, so the tiles on screen don't wait behind ones
/// scrolled past.
actor Thumbnails {
    static let shared = Thumbnails()

    /// Pixels on the long side. Big enough for the largest tile on a Retina screen.
    static let pixelSize = 480

    private nonisolated(unsafe) let memory = NSCache<NSString, NSImage>()
    private nonisolated let directory: URL
    private let maxConcurrent = 3
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Set while the viewer is open: making thumbnails waits (ones already made still show), leaving
    /// the backup drive to the photo or video being viewed. On a spinning drive, the grid under the
    /// viewer reading originals three at a time held a video's start up for half a minute.
    private var backgroundHeld = false

    init() {
        memory.countLimit = 2000
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Already made, without touching the backup drive.
    nonisolated func cached(_ url: URL, bytes: UInt64) -> NSImage? {
        memory.object(forKey: Self.key(url, bytes: bytes) as NSString)
    }

    /// Already made, from memory or this Mac's own disk; never the backup drive. A small JPEG read
    /// from the internal disk is quick enough to do while opening a photo.
    nonisolated func stored(_ url: URL, bytes: UInt64) -> NSImage? {
        let key = Self.key(url, bytes: bytes)
        if let image = memory.object(forKey: key as NSString) { return image }
        guard let image = NSImage(contentsOf: directory.appending(path: key + ".jpg")) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    func image(for url: URL, bytes: UInt64) async -> NSImage? {
        let key = Self.key(url, bytes: bytes)
        if let image = memory.object(forKey: key as NSString) { return image }
        let file = directory.appending(path: key + ".jpg")
        if let image = await Self.readCached(file) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }

        // Reading the drive waits while the viewer has it.
        await waitForBackgroundTurn()
        guard !Task.isCancelled else { return nil }
        await acquire()
        defer { release() }
        // Scrolled away while it waited: leave the drive to the tiles still on screen.
        guard !Task.isCancelled else { return nil }
        guard let cgImage = await Self.make(url) else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        memory.setObject(image, forKey: key as NSString)
        Task.detached(priority: .utility) { Self.write(cgImage, to: file) }
        return image
    }

    /// A file moved: its thumbnail, if made, goes with it, so it isn't made again from the drive.
    nonisolated func carryOver(from old: URL, to new: URL, bytes: UInt64) {
        let oldKey = Self.key(old, bytes: bytes), newKey = Self.key(new, bytes: bytes)
        guard oldKey != newKey else { return }
        if let image = memory.object(forKey: oldKey as NSString) { memory.setObject(image, forKey: newKey as NSString) }
        try? FileManager.default.moveItem(at: directory.appending(path: oldKey + ".jpg"), to: directory.appending(path: newKey + ".jpg"))
    }

    func holdBackgroundWork(_ held: Bool) {
        backgroundHeld = held
    }

    /// Returns once work that can wait may go ahead.
    func waitForBackgroundTurn() async {
        while backgroundHeld, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: Limiting reads

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        // Last in, first out: the newest request is the tile the user is looking at.
        if let next = waiting.popLast() {
            next.resume()
        } else {
            running -= 1
        }
    }

    // MARK: Making

    /// Path and size identify a file well enough: moving it into a Folder makes a new thumbnail,
    /// which is cheap next to reading every file's date.
    private static func key(_ url: URL, bytes: UInt64) -> String {
        let digest = SHA256.hash(data: Data("\(url.lexicallyStandardized.path)|\(bytes)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func readCached(_ file: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return NSImage(data: data)
        }.value
    }

    private static func make(_ url: URL) async -> CGImage? {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .movie) == true || type?.conforms(to: .audiovisualContent) == true {
            if let frame = await videoFrame(url) { return frame }
        } else if let image = await Task.detached(priority: .userInitiated, operation: { photo(url) }).value {
            return image
        }
        return await quickLook(url)
    }

    private static func photo(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func videoFrame(_ url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixelSize, height: pixelSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try? await generator.image(at: .zero).image
    }

    /// Anything Image I/O and AVFoundation can't read.
    private static func quickLook(_ url: URL) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: pixelSize / 2, height: pixelSize / 2), scale: 2, representationTypes: .all
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    private static func write(_ image: CGImage, to file: URL) {
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
