import Foundation
import ImagoKit
import SwiftUI

/// A paired iPhone. Its key lives in the Keychain; this record is not secret.
struct PairedDevice: Codable, Identifiable, Hashable {
    /// The phone's own ID, sent when pairing and in every hello.
    var id: String
    var name: String
    /// Folder under the backup location. Fixed at pairing so renaming the phone never moves files.
    var folder: String
    var pairedAt: Date
    /// Its color in the sidebar and on tiles, as hex ("DD1B3F"): one from `palette`, or any the user
    /// mixed. Nil: by the order it was paired.
    var colorHex: String? = nil

    /// A color in the palette. The name is for VoiceOver; the picker shows only the color.
    struct Swatch: Identifiable {
        let name: String
        let hex: String
        var id: String { hex }
        var color: Color { Color(hex: hex) }
    }

    /// The palette, a column per hue (from Imago's red around the wheel): bright, then soft, then deep,
    /// then a row of neutrals and earth tones.
    static let palette: [[Swatch]] = [
        [.init(name: "Red", hex: "DD1B3F"), .init(name: "Orange", hex: "FF8A00"), .init(name: "Yellow", hex: "FFC800"),
         .init(name: "Green", hex: "2DBE60"), .init(name: "Teal", hex: "14B8A6"), .init(name: "Blue", hex: "2F7CF6"),
         .init(name: "Purple", hex: "8B5CF6"), .init(name: "Pink", hex: "EC4899")],
        [.init(name: "Coral", hex: "FF7A85"), .init(name: "Apricot", hex: "FFB36B"), .init(name: "Lemon", hex: "FFE27A"),
         .init(name: "Mint", hex: "7FDCA0"), .init(name: "Aqua", hex: "67E3D2"), .init(name: "Sky", hex: "7DB5FF"),
         .init(name: "Lavender", hex: "C3A8FF"), .init(name: "Blush", hex: "F9A8D4")],
        [.init(name: "Crimson", hex: "9F1239"), .init(name: "Rust", hex: "C2410C"), .init(name: "Ochre", hex: "A16207"),
         .init(name: "Forest", hex: "15803D"), .init(name: "Pine", hex: "0F766E"), .init(name: "Navy", hex: "1D4ED8"),
         .init(name: "Violet", hex: "6D28D9"), .init(name: "Berry", hex: "BE185D")],
        [.init(name: "Charcoal", hex: "1F2937"), .init(name: "Slate", hex: "475569"), .init(name: "Gray", hex: "8A9099"),
         .init(name: "Silver", hex: "B8BEC7"), .init(name: "Sand", hex: "D2B48C"), .init(name: "Brown", hex: "8B5E3C"),
         .init(name: "Espresso", hex: "4E342E"), .init(name: "Olive", hex: "6B7D2C")],
    ]

    /// The bright row, for the quick picker in menus.
    static var brights: [Swatch] { palette[0] }

    /// Colors for iPhones in the order they were paired, far apart so neighbors are easy to tell apart.
    static let defaultColors = ["DD1B3F", "2F7CF6", "2DBE60", "FF8A00", "8B5CF6", "14B8A6", "EC4899", "FFC800"]
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
