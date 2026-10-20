import Foundation

/// Where files live in the backup folder. Plain, dated folders that stay usable without the app:
///
///     2026/10/2026-10-20_143012_IMG_4821.HEIC        original
///     2026/10/2026-10-20_143012_IMG_4821.MOV         Live Photo motion
///     2026/10/2026-10-20_143012_IMG_4821_edited.JPG  rendered edit
///     2026/10/2026-10-20_143012_IMG_4821.json        sidecar (metadata, albums, checksums)
public struct LibraryLayout: Sendable {
    public var timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    public func relativePath(for resource: ResourceDescriptor, of asset: AssetMetadata) -> String {
        let stem = Self.stem(of: Self.sanitize(asset.originalFilename))
        let ext = Self.fileExtension(of: Self.sanitize(resource.originalFilename))

        let name: String
        switch resource.key.kind {
        case .photo, .video, .alternatePhoto, .pairedVideo:
            name = Self.sanitize(resource.originalFilename)
        case .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo:
            name = "\(stem)_edited" + (ext.isEmpty ? "" : ".\(ext)")
        case .adjustmentData:
            name = "\(stem)_adjustments.plist"
        }
        return directory(for: asset) + "/" + prefix(for: asset) + name
    }

    public func sidecarPath(for asset: AssetMetadata) -> String {
        let stem = Self.stem(of: Self.sanitize(asset.originalFilename))
        return directory(for: asset) + "/" + prefix(for: asset) + stem + ".json"
    }

    /// The asset's sidecar, numbered "name (2).json"… past sidecars of other assets: a photo
    /// duplicated in Photos keeps its filename and date, so two assets can share a name.
    /// `isFree` says whether a path is unused or already holds this asset's sidecar.
    public func sidecarPath(for asset: AssetMetadata, isFree: (String) -> Bool) -> String {
        let base = sidecarPath(for: asset)
        var candidate = base
        var n = 2
        while !isFree(candidate) {
            candidate = Self.numbered(base, n)
            n += 1
        }
        return candidate
    }

    /// "2026/10/IMG_1.HEIC", 2 → "2026/10/IMG_1 (2).HEIC". Used when a name is taken.
    public static func numbered(_ path: String, _ n: Int) -> String {
        let nameStart = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        let name = String(path[nameStart...])
        let ext = fileExtension(of: name)
        return path[..<nameStart] + stem(of: name) + " (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
    }

    private func directory(for asset: AssetMetadata) -> String {
        guard let date = asset.creationDate else { return "Undated" }
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d/%02d", parts.year!, parts.month!)
    }

    private func prefix(for asset: AssetMetadata) -> String {
        guard let date = asset.creationDate else { return "" }
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d_%02d%02d%02d_", p.year!, p.month!, p.day!, p.hour!, p.minute!, p.second!)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "asset" + cleaned : cleaned
    }

    static func stem(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    static func fileExtension(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }
}

/// One JSON file per asset, next to its media. The source of truth the app's index is rebuilt from.
public struct Sidecar: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public var kind: ResourceKind
        public var revision: String
        /// Filename relative to the sidecar's folder.
        public var name: String
        public var sha256: String
        public var size: UInt64

        public init(kind: ResourceKind, revision: String, name: String, sha256: String, size: UInt64) {
            self.kind = kind
            self.revision = revision
            self.name = name
            self.sha256 = sha256
            self.size = size
        }
    }

    public var metadata: AssetMetadata
    public var files: [File]

    public init(metadata: AssetMetadata, files: [File]) {
        self.metadata = metadata
        self.files = files
    }

    /// Records a file, replacing an older revision of the same kind.
    public mutating func upsert(_ file: File) {
        files.removeAll { $0.kind == file.kind }
        files.append(file)
    }
}
