import Foundation

/// One photo or video that is on the phone right now, joined with what the Mac has of it.
public struct PhoneAsset: Codable, Sendable, Hashable, Identifiable {
    public var metadata: AssetMetadata
    /// SHA-256 of the original photo or video file, if the Mac has it.
    public var originalSHA256: String?
    /// Bytes of its files on the Mac: roughly what deleting it frees on the phone.
    public var bytes: UInt64
    /// Every file the phone has for it right now is on the Mac and checksum-verified.
    /// Only these may be offered for deletion.
    public var isBackedUp: Bool

    public init(metadata: AssetMetadata, originalSHA256: String?, bytes: UInt64, isBackedUp: Bool) {
        self.metadata = metadata
        self.originalSHA256 = originalSHA256
        self.bytes = bytes
        self.isBackedUp = isBackedUp
    }

    public var id: String { metadata.assetID }
    public var isVideo: Bool { metadata.mediaType == "video" }
    public var isScreenshot: Bool {
        if let subtypes = metadata.subtypes {
            return subtypes.contains("screenshot") || subtypes.contains("screenRecording")
        }
        // Libraries backed up before subtypes were sent: iPhone screenshots are the only PNGs it names IMG_.
        let name = metadata.originalFilename.uppercased()
        return name.hasPrefix("IMG_") && name.hasSuffix(".PNG")
    }
}

/// Suggestions for freeing space on the phone. Pure functions over the phone's library, so the Mac
/// (or another server) can show them without touching the phone.
public enum Cleanup {
    /// Assets that are the same, or nearly; one is suggested to keep, the rest to delete.
    public struct Group: Sendable, Hashable, Identifiable {
        public var assets: [PhoneAsset]
        public var keep: PhoneAsset

        public init(assets: [PhoneAsset], keep: PhoneAsset) {
            self.assets = assets
            self.keep = keep
        }

        public var id: String { keep.id }
        /// Everything except the one to keep.
        public var extras: [PhoneAsset] { assets.filter { $0.id != keep.id } }
        public var reclaimableBytes: UInt64 { extras.reduce(0) { $0 + $1.bytes } }
    }

    /// Different assets whose original files are byte-for-byte the same, e.g. a photo saved twice.
    public static func exactDuplicates(_ assets: [PhoneAsset]) -> [Group] {
        Dictionary(grouping: assets.filter { $0.originalSHA256 != nil }, by: { $0.originalSHA256! })
            .values
            .filter { $0.count > 1 }
            .map { Group(assets: sortedByDate($0), keep: largestToKeep($0)) }
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    /// Photos of one burst, which the phone keeps when the user saves more than one shot.
    public static func bursts(_ assets: [PhoneAsset], scores: [String: Double] = [:]) -> [Group] {
        Dictionary(grouping: assets.filter { $0.metadata.burstID != nil }, by: { $0.metadata.burstID! })
            .values
            .filter { $0.count > 1 }
            .map { Group(assets: sortedByDate($0), keep: bestToKeep($0, scores: scores)) }
            .sorted { ($0.keep.metadata.creationDate ?? .distantPast) > ($1.keep.metadata.creationDate ?? .distantPast) }
    }

    /// Runs of photos taken close together, oldest first. Similar shots can only be inside one run,
    /// so a similarity check only has to compare photos within each run.
    public static func moments(_ assets: [PhoneAsset], maxGap: TimeInterval = 60) -> [[PhoneAsset]] {
        let photos = assets
            .filter { !$0.isVideo && !$0.isScreenshot && $0.metadata.creationDate != nil && $0.metadata.burstID == nil }
            .sorted { $0.metadata.creationDate! < $1.metadata.creationDate! }
        var runs: [[PhoneAsset]] = []
        var current: [PhoneAsset] = []
        for photo in photos {
            if let last = current.last, photo.metadata.creationDate!.timeIntervalSince(last.metadata.creationDate!) > maxGap {
                if current.count > 1 { runs.append(current) }
                current = []
            }
            current.append(photo)
        }
        if current.count > 1 { runs.append(current) }
        return runs
    }

    /// Joins photos whose distance is under `threshold` (single linkage) and returns groups of two or more.
    /// `distance` returns nil when two photos can't be compared.
    public static func cluster(
        _ run: [PhoneAsset], threshold: Float, scores: [String: Double] = [:],
        distance: (PhoneAsset, PhoneAsset) -> Float?
    ) -> [Group] {
        var parent = Array(run.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in run.indices {
            for j in run.indices where j > i {
                if let d = distance(run[i], run[j]), d < threshold { parent[root(j)] = root(i) }
            }
        }
        return Dictionary(grouping: run.indices, by: root).values
            .filter { $0.count > 1 }
            .map { indices in
                let members = indices.map { run[$0] }
                return Group(assets: members, keep: bestToKeep(members, scores: scores))
            }
    }

    /// Videos over `minimumBytes`, biggest first.
    public static func largeVideos(_ assets: [PhoneAsset], minimumBytes: UInt64 = 100_000_000) -> [PhoneAsset] {
        assets.filter { $0.isVideo && $0.bytes >= minimumBytes }.sorted { $0.bytes > $1.bytes }
    }

    /// Screenshots and screen recordings, newest first.
    public static func screenshots(_ assets: [PhoneAsset]) -> [PhoneAsset] {
        sortedByDate(assets.filter(\.isScreenshot)).reversed()
    }

    public struct Year: Sendable, Hashable, Identifiable {
        /// nil for assets with no date.
        public var year: Int?
        public var assets: [PhoneAsset]
        public var id: Int { year ?? 0 }
        public var bytes: UInt64 { assets.reduce(0) { $0 + $1.bytes } }
    }

    /// The library by year taken, oldest first, in the given time zone.
    public static func byYear(_ assets: [PhoneAsset], timeZone: TimeZone = .current) -> [Year] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return Dictionary(grouping: assets) { $0.metadata.creationDate.map { calendar.component(.year, from: $0) } }
            .map { Year(year: $0.key, assets: sortedByDate($0.value)) }
            .sorted { ($0.year ?? .max) < ($1.year ?? .max) }
    }

    /// The asset to keep from a set of near-identical ones: a favorite first, then the best-scored
    /// (e.g. an aesthetics score), then the one in more albums, then the most pixels, then the oldest.
    public static func bestToKeep(_ assets: [PhoneAsset], scores: [String: Double] = [:]) -> PhoneAsset {
        assets.max { a, b in
            if a.metadata.isFavorite != b.metadata.isFavorite { return !a.metadata.isFavorite }
            let scoreA = scores[a.id] ?? 0, scoreB = scores[b.id] ?? 0
            if scoreA != scoreB { return scoreA < scoreB }
            if a.metadata.albums.count != b.metadata.albums.count { return a.metadata.albums.count < b.metadata.albums.count }
            let pixelsA = a.metadata.pixelWidth * a.metadata.pixelHeight, pixelsB = b.metadata.pixelWidth * b.metadata.pixelHeight
            if pixelsA != pixelsB { return pixelsA < pixelsB }
            return (a.metadata.creationDate ?? .distantFuture) > (b.metadata.creationDate ?? .distantFuture)
        }!
    }

    /// For copies of one original: the one taking the most space, which has the most with it (an
    /// edit, a Live Photo's video), so deleting the smaller ones loses nothing. Same size: `bestToKeep`.
    public static func largestToKeep(_ assets: [PhoneAsset]) -> PhoneAsset {
        let largest = assets.map(\.bytes).max() ?? 0
        return bestToKeep(assets.filter { $0.bytes == largest })
    }

    static func sortedByDate(_ assets: [PhoneAsset]) -> [PhoneAsset] {
        assets.sorted { ($0.metadata.creationDate ?? .distantPast, $0.id) < ($1.metadata.creationDate ?? .distantPast, $1.id) }
    }
}
