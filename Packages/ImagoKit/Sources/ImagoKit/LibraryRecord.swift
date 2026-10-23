import Foundation

/// `.photobackup/library.json` at the root of the backup location: which library this is and which
/// phone backs up into which folder. It travels with the folder, so another Mac (or this one, after
/// the folder moved to a new drive) knows whose photos are where, and a re-paired phone carries on
/// in its old folder instead of starting a new one.
///
/// Keys are never stored here: a phone pairs again with each Mac.
public struct LibraryRecord: Codable, Sendable, Equatable {
    public struct Device: Codable, Sendable, Equatable {
        public var deviceID: String
        public var name: String
        /// Folder under the backup location. Fixed once given out, so renaming the phone never moves files.
        public var folder: String

        public init(deviceID: String, name: String, folder: String) {
            self.deviceID = deviceID
            self.name = name
            self.folder = folder
        }
    }

    public static let relativePath = ".photobackup/library.json"

    /// Made once, when the library is created, and kept forever.
    public var libraryID: String
    public var createdAt: Date
    /// Every phone that has a folder here. Removing a phone from a Mac doesn't remove it from this list,
    /// so pairing it again finds its folder.
    public var devices: [Device]

    public init(libraryID: String = UUID().uuidString, createdAt: Date = .now, devices: [Device] = []) {
        self.libraryID = libraryID
        self.createdAt = createdAt
        self.devices = devices
    }

    public func device(_ deviceID: String) -> Device? {
        devices.first { $0.deviceID == deviceID }
    }

    /// The phone's folder here, giving it `preferred` if no other phone has that folder, or the
    /// first free "name 2", "name 3"… otherwise. An already-listed phone keeps its folder.
    @discardableResult
    public mutating func folder(for deviceID: String, name: String, preferred: String) -> String {
        if let index = devices.firstIndex(where: { $0.deviceID == deviceID }) {
            devices[index].name = name
            return devices[index].folder
        }
        let taken = Set(devices.map { $0.folder.lowercased() })
        var candidate = preferred
        var n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(preferred) \(n)"
            n += 1
        }
        devices.append(Device(deviceID: deviceID, name: name, folder: candidate))
        return candidate
    }

    /// The record in `root`, or nil if the folder has none yet.
    public static func load(from root: URL) throws -> LibraryRecord? {
        let url = root.appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryRecord.self, from: Data(contentsOf: url))
    }

    public func save(to root: URL) throws {
        let url = root.appending(path: Self.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
