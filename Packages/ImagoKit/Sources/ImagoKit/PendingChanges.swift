import Foundation

/// The phone's library as it will be once the changes waiting for it are done, so the server can show
/// a change the moment it's made. Also keeps the queue short: undoing a change takes it out of the
/// queue instead of adding its opposite, so the phone isn't asked to favorite and then unfavorite.
public enum PendingChanges {
    /// The assets with every waiting change made to them, except deletions: assets waiting to be deleted
    /// are left in, so a caller can show them on their way out (see `deleting`).
    public static func apply(_ changes: [LibraryChange], to assets: [PhoneAsset]) -> [PhoneAsset] {
        guard !changes.isEmpty else { return assets }
        let byID = Dictionary(assets.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result = assets
        for change in changes {
            for id in change.assetIDs {
                guard let index = byID[id] else { continue }
                apply(change.action, to: &result[index].metadata)
            }
        }
        return result
    }

    /// Makes a change to one asset's metadata. Deletion leaves it as it is.
    public static func apply(_ action: LibraryChange.Action, to metadata: inout AssetMetadata) {
        switch action {
        case .delete:
            break
        case .setFavorite(let on):
            metadata.isFavorite = on
        case .addToAlbum(let title):
            if !metadata.albums.contains(title) { metadata.albums.append(title) }
        case .removeFromAlbum(let title):
            metadata.albums.removeAll { $0 == title }
        }
    }

    /// Assets waiting to be deleted.
    public static func deleting(_ changes: [LibraryChange]) -> Set<String> {
        Set(changes.filter { $0.action == .delete }.flatMap(\.assetIDs))
    }

    /// Assets with any change waiting.
    public static func touched(_ changes: [LibraryChange]) -> Set<String> {
        Set(changes.flatMap(\.assetIDs))
    }

    /// The phone's album titles plus the ones a waiting change will create, in their original order.
    public static func albums(_ albums: [String], with changes: [LibraryChange]) -> [String] {
        var result = albums
        for change in changes {
            if case .addToAlbum(let title) = change.action, !result.contains(title) { result.append(title) }
        }
        return result
    }

    /// Adds `change` to the waiting changes. An opposite change still waiting for the same assets is
    /// taken back instead, and assets already as asked (on the phone at its last backup, in `base`)
    /// are left out. Returns the new queue, without `change` if nothing is left of it.
    public static func queue(_ change: LibraryChange, onto pending: [LibraryChange], base: [String: AssetMetadata]) -> [LibraryChange] {
        let ids = Set(change.assetIDs)
        let opposite = opposite(of: change.action)
        var queue: [LibraryChange] = []
        var alreadyQueued: Set<String> = []
        for var waiting in pending {
            if let opposite, waiting.action == opposite {
                waiting.assetIDs.removeAll { ids.contains($0) }
                if waiting.assetIDs.isEmpty { continue }
            } else if waiting.action == change.action {
                alreadyQueued.formUnion(waiting.assetIDs.filter { ids.contains($0) })
            }
            queue.append(waiting)
        }

        var new = change
        new.assetIDs = change.assetIDs.filter { id in
            guard !alreadyQueued.contains(id) else { return false }
            guard let metadata = base[id] else { return true }
            return switch change.action {
            case .delete: true
            case .setFavorite(let on): metadata.isFavorite != on
            case .addToAlbum(let title): !metadata.albums.contains(title)
            case .removeFromAlbum(let title): metadata.albums.contains(title)
            }
        }
        guard !new.assetIDs.isEmpty else { return queue }
        if let bytes = change.bytes, new.assetIDs.count < change.assetIDs.count {
            new.bytes = bytes / UInt64(change.assetIDs.count) * UInt64(new.assetIDs.count)
        }
        queue.append(new)
        return queue
    }

    /// Takes `ids` out of every waiting change with `action`, e.g. to keep items on the phone after
    /// all. Changes left with no assets are dropped.
    public static func withdraw(_ ids: Set<String>, from action: LibraryChange.Action, in pending: [LibraryChange]) -> [LibraryChange] {
        pending.compactMap { change in
            guard change.action == action else { return change }
            var change = change
            let before = change.assetIDs.count
            change.assetIDs.removeAll { ids.contains($0) }
            if let bytes = change.bytes, change.assetIDs.count < before {
                change.bytes = bytes / UInt64(before) * UInt64(change.assetIDs.count)
            }
            return change.assetIDs.isEmpty ? nil : change
        }
    }

    private static func opposite(of action: LibraryChange.Action) -> LibraryChange.Action? {
        switch action {
        case .delete: nil
        case .setFavorite(let on): .setFavorite(!on)
        case .addToAlbum(let title): .removeFromAlbum(title)
        case .removeFromAlbum(let title): .addToAlbum(title)
        }
    }
}

/// The phone's "Media Types", as in the Photos app.
public enum PhoneMediaType: String, CaseIterable, Sendable, Identifiable {
    case videos, livePhotos, portrait, panoramas, slowMotion, timeLapse, cinematic, spatial, screenshots, screenRecordings

    public var id: Self { self }

    public var title: String {
        switch self {
        case .videos: "Videos"
        case .livePhotos: "Live Photos"
        case .portrait: "Portrait"
        case .panoramas: "Panoramas"
        case .slowMotion: "Slo-mo"
        case .timeLapse: "Time-lapse"
        case .cinematic: "Cinematic"
        case .spatial: "Spatial"
        case .screenshots: "Screenshots"
        case .screenRecordings: "Screen Recordings"
        }
    }

    /// SF Symbol for the sidebar.
    public var symbol: String {
        switch self {
        case .videos: "video"
        case .livePhotos: "livephoto"
        case .portrait: "cube"
        case .panoramas: "pano"
        case .slowMotion: "slowmo"
        case .timeLapse: "timelapse"
        case .cinematic: "film"
        case .spatial: "pano.badge.play"
        case .screenshots: "camera.viewfinder"
        case .screenRecordings: "record.circle"
        }
    }

    public func contains(_ asset: PhoneAsset) -> Bool {
        let subtypes = asset.metadata.subtypes ?? []
        return switch self {
        case .videos: asset.isVideo
        case .livePhotos: subtypes.contains("livePhoto")
        case .portrait: subtypes.contains("depthEffect")
        case .panoramas: subtypes.contains("panorama")
        case .slowMotion: subtypes.contains("highFrameRate")
        case .timeLapse: subtypes.contains("timelapse")
        case .cinematic: subtypes.contains("cinematic")
        case .spatial: subtypes.contains("spatial")
        case .screenshots: asset.isScreenshot && !subtypes.contains("screenRecording")
        case .screenRecordings: subtypes.contains("screenRecording")
        }
    }
}

extension Cleanup {
    public struct Month: Sendable, Hashable, Identifiable {
        /// Both nil for assets with no date.
        public var year: Int?
        public var month: Int?
        public var assets: [PhoneAsset]
        public var id: Int { (year ?? 0) * 100 + (month ?? 0) }
        public var bytes: UInt64 { assets.reduce(0) { $0 + $1.bytes } }
    }

    /// The library by month taken, oldest first and undated last, in the given time zone.
    public static func byMonth(_ assets: [PhoneAsset], timeZone: TimeZone = .current) -> [Month] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return Dictionary(grouping: assets) { asset -> Int in
            guard let date = asset.metadata.creationDate else { return .max }
            let parts = calendar.dateComponents([.year, .month], from: date)
            return parts.year! * 100 + parts.month!
        }
        .map { key, assets in
            key == .max ? Month(year: nil, month: nil, assets: sortedByDate(assets))
                        : Month(year: key / 100, month: key % 100, assets: sortedByDate(assets))
        }
        .sorted { ($0.year == nil ? Int.max : $0.id) < ($1.year == nil ? Int.max : $1.id) }
    }
}
