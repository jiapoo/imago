import ImagoKit
import SwiftUI

/// The phone's library as of its last backup, shown as it will be once the changes waiting for the
/// phone are done. Changes made here are queued for the phone; nothing happens on it until the user
/// confirms there.
///
/// One model per phone lives for the whole session, so going back to a phone's Photos is instant.
/// The first open shows a copy kept on this Mac's own disk, then refreshes from the backup drive,
/// which can take many seconds when the drive is asleep.
@MainActor @Observable
final class PhoneLibraryModel {
    private static var models: [String: PhoneLibraryModel] = [:]

    static func model(for device: PairedDevice) -> PhoneLibraryModel {
        if let model = models[device.id] { return model }
        let model = PhoneLibraryModel(device: device)
        models[device.id] = model
        return model
    }

    enum State: Equatable {
        case loading
        /// The backup drive isn't connected.
        case unavailable
        /// The phone hasn't backed up with a version that sends its library list.
        case noSnapshot
        case ready
    }

    let device: PairedDevice
    private(set) var state: State = .loading
    private(set) var takenAt: Date?
    private(set) var queue = ChangeQueue()
    /// The backed-up original of each asset (the rendered edit if that's all there is), for thumbnails.
    private(set) var files: [String: URL] = [:]
    /// What each asset's thumbnail is keyed by (see `PhoneLibrary.thumbnailBytes`).
    private(set) var thumbnailBytes: [String: UInt64] = [:]

    /// As on the phone at its last backup, oldest first. Changes are asked for against these.
    private(set) var base: [PhoneAsset] = []
    /// As it will be once the waiting changes are done, newest first, leaving out assets waiting to be deleted.
    private(set) var assets: [PhoneAsset] = []
    /// Waiting to be deleted, newest first.
    private(set) var deleting: [PhoneAsset] = []
    /// Files in this iPhone's folder on the drive that the iPhone doesn't have, such as an edited copy
    /// saved beside its original. Shown in the library marked Not synced; nothing is asked of the iPhone.
    private(set) var unsynced: [PhoneAsset] = []
    /// `assets` with `unsynced` among them, newest first: what the library's grids show.
    private(set) var libraryAssets: [PhoneAsset] = []
    private var unsyncedFiles: [String: URL] = [:]
    private var unsyncedByID: [String: PhoneAsset] = [:]
    /// Assets with any change waiting.
    private(set) var waiting: Set<String> = []
    /// The phone's albums and the ones waiting changes will create, sorted.
    private(set) var albums: [String] = []
    private(set) var albumCounts: [String: Int] = [:]
    private(set) var mediaTypeCounts: [PhoneMediaType: Int] = [:]

    private(set) var duplicates: [Cleanup.Group] = []
    private(set) var bursts: [Cleanup.Group] = []
    private(set) var similar: [Cleanup.Group]?
    private(set) var similarProgress: Double?
    private(set) var largeVideos: [PhoneAsset] = []
    /// Bumped whenever what's shown changes, so grids regroup only then.
    private(set) var revision = 0
    /// A section to open the Photos page at, e.g. Large Videos from the iPhone's page. Taken once.
    var requestedSection: PhoneSection?

    private var baseByID: [String: PhoneAsset] = [:]
    /// As shown (waiting changes made), by ID, waiting deletions included.
    private var shownByID: [String: PhoneAsset] = [:]
    private var phoneAlbums: [String] = []
    /// What was last read from the drive, to save as the local copy.
    private var library: PhoneLibrary?
    /// Which snapshot `base` was read from, so a change to the queue alone doesn't read it again.
    private var loadedSnapshot: String?
    private var similarTask: Task<Void, Never>?

    private init(device: PairedDevice) {
        self.device = device
    }

    var favorites: [PhoneAsset] { assets.filter(\.metadata.isFavorite) }
    var notBackedUp: [PhoneAsset] { assets.filter { !$0.isBackedUp } }
    var backedUpCount: Int { base.count { $0.isBackedUp } }

    func assets(inAlbum album: String) -> [PhoneAsset] {
        assets.filter { $0.metadata.albums.contains(album) }
    }

    func assets(of type: PhoneMediaType) -> [PhoneAsset] {
        assets.filter(type.contains)
    }

    /// The asset as shown, with waiting changes made.
    func asset(_ id: String) -> PhoneAsset? {
        shownByID[id] ?? unsyncedByID[id]
    }

    /// Takes the drive's files in this iPhone's folder that aren't its backups (see `unsynced`).
    func setUnsynced(_ items: [MediaItem]) {
        let assets = items.map(PhoneAsset.unsynced)
        guard assets != unsynced else { return }
        for id in unsyncedFiles.keys { files[id] = nil }
        unsynced = assets
        unsyncedByID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        unsyncedFiles = Dictionary(items.map { (PhoneAsset.unsyncedPrefix + $0.url.path, $0.url) }, uniquingKeysWith: { a, _ in a })
        files.merge(unsyncedFiles) { _, new in new }
        mergeLibraryAssets()
        revision += 1
    }

    private func mergeLibraryAssets() {
        libraryAssets = unsynced.isEmpty ? assets : (assets + unsynced).sorted {
            ($0.metadata.creationDate ?? .distantPast) > ($1.metadata.creationDate ?? .distantPast)
        }
    }

    /// The assets as they were on the phone, for asking it to change them.
    func baseAssets(_ ids: some Sequence<String>) -> [PhoneAsset] {
        ids.compactMap { baseByID[$0] }
    }

    // MARK: Loading

    func load(from server: BackupServer) async {
        guard let store = server.store(for: device) else { state = .unavailable; return }
        let location = server.location.url.path
        if state != .ready, let copy = await LocalCopy.read(device.id), copy.location == location {
            show(copy.library)
            queue = copy.queue
            rebuild()
            state = .ready
        }

        var changed = false
        let snapshotKey = "\(server.catalogRevision)|\(server.indexRevision[device.id, default: 0])|\(await store.snapshotModified()?.timeIntervalSince1970 ?? 0)"
        if snapshotKey != loadedSnapshot {
            guard let library = await store.phoneLibrary() else { state = .noSnapshot; return }
            loadedSnapshot = snapshotKey
            show(library)
            changed = true
        }
        let fresh = await store.changeQueue()
        if fresh != queue {
            queue = fresh
            changed = true
        }
        if changed {
            rebuild()
            if let library { LocalCopy.write(.init(location: location, library: library, queue: queue), for: device.id) }
        }
        state = .ready
    }

    private func show(_ library: PhoneLibrary) {
        if library.takenAt != takenAt { similar = nil }
        self.library = library
        takenAt = library.takenAt
        files = library.files.merging(unsyncedFiles) { _, new in new }
        thumbnailBytes = library.thumbnailBytes
        base = library.assets
        baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        phoneAlbums = library.albums
    }

    /// Lays the waiting changes over the snapshot and works out everything shown from that.
    private func rebuild() {
        let pending = queue.pending
        let deletingIDs = PendingChanges.deleting(pending)
        let effective = PendingChanges.apply(pending, to: base)
        shownByID = Dictionary(effective.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newestFirst = effective.reversed()
        assets = newestFirst.filter { !deletingIDs.contains($0.id) }
        mergeLibraryAssets()
        deleting = newestFirst.filter { deletingIDs.contains($0.id) }
        waiting = PendingChanges.touched(pending)

        albums = PendingChanges.albums(phoneAlbums, with: pending)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var counts: [String: Int] = [:]
        for asset in assets {
            for album in asset.metadata.albums { counts[album, default: 0] += 1 }
        }
        albumCounts = counts
        mediaTypeCounts = Dictionary(uniqueKeysWithValues: PhoneMediaType.allCases.map { type in (type, assets.count(where: type.contains)) })

        let visible = effective.filter { !deletingIDs.contains($0.id) }
        duplicates = Cleanup.exactDuplicates(visible)
        bursts = Cleanup.bursts(visible)
        largeVideos = Cleanup.largeVideos(visible)
        if let similar {
            // Drop what's been queued for deletion since.
            self.similar = similar.compactMap { group in
                let left = group.assets.filter { !deletingIDs.contains($0.id) }
                return left.count > 1 ? Cleanup.Group(assets: left, keep: left.contains(group.keep) ? group.keep : Cleanup.bestToKeep(left)) : nil
            }
        }
        revision += 1
    }

    // MARK: Similar shots

    func findSimilar() {
        similarTask?.cancel()
        similarProgress = 0
        let deletingIDs = Set(deleting.map(\.id))
        let assets = base.filter { !deletingIDs.contains($0.id) }
        let files = files
        similarTask = Task {
            let groups = await SimilarPhotos.find(in: assets, files: files) { [weak self] in self?.similarProgress = $0 }
            if !Task.isCancelled { similar = groups }
            similarProgress = nil
        }
    }

    func cancelSimilar() {
        similarTask?.cancel()
        similarProgress = nil
    }
}

/// The phone's library and queue as last read from the backup drive, kept in this Mac's Caches folder.
/// Only for showing quickly: it's replaced by what's on the drive as soon as that's read.
private enum LocalCopy {
    struct Contents: Codable {
        /// The backup location it came from; a copy from another location isn't used.
        var location: String
        var library: PhoneLibrary
        var queue: ChangeQueue
    }

    private static func url(for deviceID: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "PhoneLibraries/\(deviceID).json")
    }

    static func read(_ deviceID: String) async -> Contents? {
        let url = url(for: deviceID)
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Contents.self, from: data)
        }.value
    }

    static func write(_ contents: Contents, for deviceID: String) {
        let url = url(for: deviceID)
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoder.encode(contents).write(to: url, options: .atomic)
        }
    }
}

extension PhoneAsset {
    static let unsyncedPrefix = "unsynced:"

    /// A file on the drive that isn't on the iPhone (see `PhoneLibraryModel.unsynced`).
    var isUnsynced: Bool { id.hasPrefix(Self.unsyncedPrefix) }

    static func unsynced(_ item: MediaItem) -> PhoneAsset {
        PhoneAsset(
            metadata: AssetMetadata(
                assetID: unsyncedPrefix + item.url.path, originalFilename: item.name, creationDate: item.date,
                modificationDate: nil, mediaType: item.isVideo ? "video" : "image", pixelWidth: 0, pixelHeight: 0,
                duration: item.duration, isFavorite: false, location: nil, albums: []
            ),
            originalSHA256: nil, bytes: item.bytes, isBackedUp: true
        )
    }
}
