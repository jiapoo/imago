import Foundation

public enum ProtocolVersion {
    public static let current = 6
    /// Versions the Mac still accepts. A version-4 phone backs up as before; it just never opens a live
    /// session. Changes a phone's version doesn't know (`LibraryChange.Action.minimumVersion`) aren't sent to it.
    public static let supported = 4...6
}

/// Which file of an asset a resource is. Mirrors the PHAssetResourceType cases worth keeping.
public enum ResourceKind: String, Codable, Sendable, CaseIterable {
    case photo                 // original still (HEIC, JPEG, DNG…)
    case video                 // original video
    case alternatePhoto        // e.g. the JPEG half of a RAW+JPEG pair
    case pairedVideo           // Live Photo motion
    case fullSizePhoto         // rendered edit
    case fullSizeVideo         // rendered edit
    case fullSizePairedVideo   // rendered Live Photo edit
    case adjustmentData        // the edit recipe

    /// Edits can change over time; originals never do.
    public var isEdit: Bool {
        switch self {
        case .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo, .adjustmentData: true
        default: false
        }
    }
}

/// Stable identity of one file. `revision` is "original" for originals and the asset's
/// modification stamp for edits, so re-editing a photo produces a new key.
public struct ResourceKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public var assetID: String
    public var kind: ResourceKind
    public var revision: String

    public init(assetID: String, kind: ResourceKind, revision: String) {
        self.assetID = assetID
        self.kind = kind
        self.revision = revision
    }

    public var description: String { "\(assetID)#\(kind.rawValue)@\(revision)" }
}

public struct AssetMetadata: Codable, Sendable, Hashable {
    public struct Location: Codable, Sendable, Hashable {
        public var latitude: Double
        public var longitude: Double
        public var altitude: Double

        public init(latitude: Double, longitude: Double, altitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
        }
    }

    public var assetID: String
    /// Filename of the primary resource (IMG_4821.HEIC); names every file of the asset on disk.
    public var originalFilename: String
    public var creationDate: Date?
    public var modificationDate: Date?
    public var mediaType: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var duration: Double
    public var isFavorite: Bool
    public var location: Location?
    public var albums: [String]
    /// PhotoKit subtypes, e.g. "screenshot", "screenRecording", "livePhoto", "panorama", "hdr",
    /// "depthEffect", "highFrameRate", "timelapse", "cinematic", "spatial". Absent before version 4.
    public var subtypes: [String]?
    /// Shared by the photos of one burst.
    public var burstID: String?

    public init(
        assetID: String, originalFilename: String, creationDate: Date?, modificationDate: Date?,
        mediaType: String, pixelWidth: Int, pixelHeight: Int, duration: Double,
        isFavorite: Bool, location: Location?, albums: [String], subtypes: [String]? = nil, burstID: String? = nil
    ) {
        self.subtypes = subtypes
        self.burstID = burstID
        self.assetID = assetID
        self.originalFilename = originalFilename
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.mediaType = mediaType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.isFavorite = isFavorite
        self.location = location
        self.albums = albums
    }
}

public struct ResourceDescriptor: Codable, Sendable, Hashable {
    public var key: ResourceKey
    public var originalFilename: String
    public var uti: String

    public init(key: ResourceKey, originalFilename: String, uti: String) {
        self.key = key
        self.originalFilename = originalFilename
        self.uti = uti
    }
}

public struct ManifestEntry: Codable, Sendable, Hashable {
    public var metadata: AssetMetadata
    public var resources: [ResourceDescriptor]

    public init(metadata: AssetMetadata, resources: [ResourceDescriptor]) {
        self.metadata = metadata
        self.resources = resources
    }
}

/// A small JPEG preview of one asset, at most `Thumbnail.pixelSize` on the long side.
public struct Thumbnail: Codable, Sendable, Hashable {
    public static let pixelSize = 360

    public var assetID: String
    public var jpeg: Data

    public init(assetID: String, jpeg: Data) {
        self.assetID = assetID
        self.jpeg = jpeg
    }
}

/// A resource the Mac still needs, and how many bytes of it it already has.
public struct ResumePoint: Codable, Sendable, Hashable {
    public var key: ResourceKey
    public var offset: UInt64

    public init(key: ResourceKey, offset: UInt64) {
        self.key = key
        self.offset = offset
    }
}

/// Pairing (on the Mac's pairing service, only while "Add iPhone" is open):
///   pairRequest → paired(Mac)            the Mac issues this phone its own key
///
/// Backup session (phone → Mac unless noted):
///   hello(proof) → welcome | unavailable(Mac)
///   changeReport                         only if the phone acted on changes since last time
///   manifest(batch) → need(Mac)          repeated per batch
///   manifestEnd → changes(Mac)           the Mac's pending library changes, maybe none
///   beginResource, chunk…, endResource → stored | failed (Mac)
///   goodbye
///
/// Live session (version 5, while Imago is open on the phone; a second connection beside any backup):
///   hello(proof) → welcome | unavailable(Mac)
///   live → changes(Mac)                  then the Mac sends `changes` again whenever its queue changes
///   changeReport                         as soon as the user acts on changes
///   thumbnailRequest(Mac) → thumbnails   previews of photos the Mac hasn't backed up yet
///   goodbye, or the connection just closes when the app leaves the screen
public enum ControlMessage: Codable, Sendable, Equatable {
    case pairRequest(deviceID: String, deviceName: String, protocolVersion: Int)
    case paired(deviceKey: Data, serverName: String)
    /// `proof` is `HelloProof.make(…)`. Optional only so a phone from before version 3 still
    /// decodes and gets a readable "update the app" reply; the Mac refuses a hello without it.
    case hello(deviceID: String, deviceName: String, protocolVersion: Int, proof: Data?)
    case welcome(serverName: String)
    /// The Mac can't take backups right now, e.g. its backup drive is unplugged.
    case unavailable(reason: String)
    case manifest([ManifestEntry])
    case need([ResumePoint])
    case beginResource(ResourceDescriptor, metadata: AssetMetadata, size: UInt64)
    case endResource(ResourceKey, sha256: String)
    case stored(ResourceKey)
    case failed(ResourceKey, reason: String)
    case goodbye
    /// The phone's whole library has been sent. `albums` lists every album title, empty ones too.
    case manifestEnd(albums: [String])
    /// Changes the Mac asks the phone to make. The phone shows them to the user before doing anything.
    case changes([LibraryChange])
    /// What happened to changes the phone received earlier.
    case changeReport([ChangeReport])
    /// Version 5: the app is open on the phone. The Mac keeps the connection and pushes `changes` to it.
    case live
    /// Version 5: the Mac asks for small previews of these assets, which it has no backed-up copy of yet.
    case thumbnailRequest([String])
    /// Version 5: previews the Mac asked for. Assets the phone no longer has are left out.
    case thumbnails([Thumbnail])

    /// Every message name on the wire. A name not in here comes from a newer version and is skipped.
    public static let names: Set<String> = [
        "pairRequest", "paired", "hello", "welcome", "unavailable", "manifest", "need", "beginResource",
        "endResource", "stored", "failed", "goodbye", "manifestEnd", "changes", "changeReport",
        "live", "thumbnailRequest", "thumbnails",
    ]
}
