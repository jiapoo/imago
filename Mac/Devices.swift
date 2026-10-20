import Foundation
import PhotoBackupKit

/// A paired iPhone. Its key lives in the Keychain; this record is not secret.
struct PairedDevice: Codable, Identifiable, Hashable {
    /// The phone's own ID, sent when pairing and in every hello.
    var id: String
    var name: String
    /// Folder under the backup location. Fixed at pairing so renaming the phone never moves files.
    var folder: String
    var pairedAt: Date
}

enum DeviceRegistry {
    private static let devicesKey = "pairedDevices"
    private static let keysAccount = "device-keys"

    static func loadDevices() -> [PairedDevice] {
        guard let data = UserDefaults.standard.data(forKey: devicesKey) else { return [] }
        return (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
    }

    static func saveDevices(_ devices: [PairedDevice]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(devices), forKey: devicesKey)
    }

    static func loadKeys() -> [String: Data] {
        guard let data = Keychain.load(account: keysAccount) else { return [:] }
        return (try? JSONDecoder().decode([String: Data].self, from: data)) ?? [:]
    }

    static func saveKeys(_ keys: [String: Data]) {
        if let data = try? JSONEncoder().encode(keys) {
            try? Keychain.save(data, account: keysAccount)
        }
    }

    /// "Jia's iPhone", or "Jia's iPhone 2" if that folder is already taken.
    static func folderName(for name: String, taken: Set<String>, in location: URL) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let base = cleaned.isEmpty ? "iPhone" : cleaned
        var candidate = base
        var n = 2
        while taken.contains(candidate) || FileManager.default.fileExists(atPath: location.appending(path: candidate).path) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }
}

/// Where backups go, and what kind of disk that is.
struct LocationInfo: Equatable {
    enum Kind { case internalDisk, external, network }

    var url: URL
    var isAvailable: Bool
    var volumeName: String
    var kind: Kind
    var availableBytes: Int64?
    var totalBytes: Int64?

    init(url: URL) {
        self.url = url
        var isDirectory: ObjCBool = false
        isAvailable = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: url.path)

        let values = isAvailable ? try? url.resourceValues(forKeys: [
            .volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey,
        ]) : nil

        let components = url.standardizedFileURL.pathComponents
        let mountedName = components.count > 2 && components[1] == "Volumes" ? components[2] : nil
        volumeName = values?.volumeName ?? mountedName ?? "This Mac"

        if values?.volumeIsLocal == false {
            kind = .network
        } else if values?.volumeIsInternal == false || (values == nil && mountedName != nil) {
            kind = .external
        } else {
            kind = .internalDisk
        }
        availableBytes = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
        totalBytes = values?.volumeTotalCapacity.map(Int64.init)
    }

    var symbol: String {
        switch kind {
        case .internalDisk: "internaldrive.fill"
        case .external: "externaldrive.fill"
        case .network: "server.rack"
        }
    }

    var kindDescription: String {
        switch kind {
        case .internalDisk: "Internal disk"
        case .external: "External drive"
        case .network: "Network drive"
        }
    }

    /// The sandbox container path shown as the real one, e.g. "~/Pictures/Photo Backup".
    var displayPath: String {
        let path = url.path(percentEncoded: false)
        if let range = path.range(of: "/Library/Containers/"), let data = path.range(of: "/Data/", range: range.upperBound..<path.endIndex) {
            return "~/" + path[data.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return path.hasPrefix(home) ? "~/" + path.dropFirst(home.count) : path
    }

    var usedFraction: Double? {
        guard let availableBytes, let totalBytes, totalBytes > 0 else { return nil }
        return 1 - Double(availableBytes) / Double(totalBytes)
    }
}
