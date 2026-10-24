import ImagoKit
import SwiftUI

/// The phone's library as of its last backup, shown as it will be once the changes waiting for the
/// phone are done. Changes made here are queued for the phone; nothing happens on it until the user
/// confirms there.
@MainActor @Observable
final class PhoneLibraryModel {
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

    /// As on the phone at its last backup, oldest first. Changes are asked for against these.
    private(set) var base: [PhoneAsset] = []
    /// As it will be once the waiting changes are done, newest first, leaving out assets waiting to be deleted.
    private(set) var assets: [PhoneAsset] = []
    /// Waiting to be deleted, newest first.
    private(set) var deleting: [PhoneAsset] = []
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

    private var baseByID: [String: PhoneAsset] = [:]
    private var phoneAlbums: [String] = []
    /// Which snapshot `base` was read from, so a change to the queue alone doesn't read it again.
    private var loadedSnapshot: String?
    private var similarTask: Task<Void, Never>?

    init(device: PairedDevice) {
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

    /// The assets as they were on the phone, for asking it to change them.
    func baseAssets(_ ids: some Sequence<String>) -> [PhoneAsset] {
        ids.compactMap { baseByID[$0] }
    }

    // MARK: Loading

    func load(from server: BackupServer) async {
        guard let store = server.store(for: device) else { state = .unavailable; return }
        let snapshotKey = "\(server.catalogRevision)|\(await store.snapshotModified()?.timeIntervalSince1970 ?? 0)"
        if snapshotKey != loadedSnapshot {
            guard let library = await store.phoneLibrary() else { state = .noSnapshot; return }
            loadedSnapshot = snapshotKey
            if library.takenAt != takenAt { similar = nil }
            takenAt = library.takenAt
            files = library.files
            base = library.assets
            baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            phoneAlbums = library.albums
        }
        queue = await store.changeQueue()
        rebuild()
        state = .ready
    }

    /// Lays the waiting changes over the snapshot and works out everything shown from that.
    private func rebuild() {
        let pending = queue.pending
        let deletingIDs = PendingChanges.deleting(pending)
        let effective = PendingChanges.apply(pending, to: base)
        let newestFirst = effective.reversed()
        assets = newestFirst.filter { !deletingIDs.contains($0.id) }
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
