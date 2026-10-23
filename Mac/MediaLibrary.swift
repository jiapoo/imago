import AppKit
import ImagoKit
import SwiftUI
import UniformTypeIdentifiers

/// One photo or video in the backup: from a phone, with a sidecar, or a file put into a Folder
/// some other way (AirDrop, Finder).
struct MediaItem: Identifiable, Hashable, Sendable {
    /// "deviceID/assetID" for a phone's asset, the file's path otherwise.
    var id: String
    var url: URL
    var name: String
    var date: Date?
    var isVideo: Bool
    var duration: Double
    var bytes: UInt64
    /// The Folder it's in; nil while it's still in its phone's folder.
    var folder: String?
    /// The phone it came from and its asset there. Nil for files that didn't come from a phone.
    var deviceID: String?
    var assetID: String?
}

/// Everything in the backup library, across phones and Folders. Built from each phone's index, so
/// opening it doesn't read the whole drive; only the Folders themselves are listed.
@MainActor @Observable
final class MediaLibrary {
    nonisolated static let foldersName = "Folders"

    enum State: Equatable { case loading, unavailable, ready }

    enum Scope: Hashable {
        case all
        case folder(String)
    }

    enum Kind: String, CaseIterable, Identifiable {
        case all, photos, videos
        var id: Self { self }
    }

    struct Folder: Identifiable, Hashable {
        var name: String
        var count: Int
        var bytes: UInt64
        var id: String { name }
    }

    private(set) var state: State = .loading
    private(set) var items: [MediaItem] = []
    private(set) var folders: [Folder] = []
    /// What each phone had at its last backup: device ID → asset ID → asset.
    private(set) var onPhone: [String: [String: PhoneAsset]] = [:]
    /// Assets already queued for removal from their phone, as item IDs.
    private(set) var pendingRemoval: Set<String> = []
    /// Shared with the sidebar, so dropping one selected item on a Folder moves the whole selection.
    var selection: Set<MediaItem.ID> = []
    var error: String?

    private var loadedRevision: Int?

    // MARK: Reading

    func load(from server: BackupServer, force: Bool = false) async {
        guard force || loadedRevision != server.catalogRevision else { return }
        loadedRevision = server.catalogRevision
        guard server.location.isAvailable else {
            state = .unavailable
            items = []
            folders = []
            return
        }
        if items.isEmpty { state = .loading }

        let foldersURL = server.foldersURL
        var loaded: [MediaItem] = []
        var phones: [String: [String: PhoneAsset]] = [:]
        var pending: Set<String> = []
        var stores: [BackupStore] = []
        var known: Set<URL> = []
        for device in server.devices {
            guard let store = server.store(for: device) else { continue }
            stores.append(store)
            for entry in await store.catalog() {
                known.formUnion(entry.files.map(\.url))
                guard let display = entry.display else { continue }
                loaded.append(MediaItem(
                    id: "\(device.id)/\(entry.assetID)", url: display.url,
                    name: entry.metadata.originalFilename, date: entry.metadata.creationDate,
                    isVideo: entry.metadata.mediaType == "video", duration: entry.metadata.duration,
                    bytes: entry.files.reduce(0) { $0 + $1.size },
                    folder: Self.folder(of: display.url, in: foldersURL),
                    deviceID: device.id, assetID: entry.assetID
                ))
            }
            if let library = await store.phoneLibrary() {
                phones[device.id] = Dictionary(library.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
            for change in await store.changeQueue().pending where change.action == .delete {
                pending.formUnion(change.assetIDs.map { "\(device.id)/\($0)" })
            }
        }

        // Files in Folders that no phone's index knows: added another way, or moved there in Finder.
        // Listing them reads the drive, which can take a while on a slow one, so it's off the main thread.
        let (unknown, folderNames) = await Task.detached(priority: .userInitiated) {
            (Self.mediaFiles(in: foldersURL).filter { !known.contains($0) }, Self.folderNames(in: foldersURL))
        }.value
        var relinked = false
        for url in unknown {
            var claimed = false
            for store in stores where (try? await store.relink(url)) == true {
                claimed = true
                break
            }
            if claimed {
                relinked = true
            } else {
                loaded.append(Self.fileItem(url, in: foldersURL))
            }
        }
        if relinked {
            // Moved in Finder: read again so they show up with their phone's details.
            await load(from: server, force: true)
            return
        }

        items = loaded.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        onPhone = phones
        pendingRemoval = pending
        let byFolder = Dictionary(grouping: items.filter { $0.folder != nil }, by: { $0.folder! })
        folders = folderNames.map { name in
            let inside = byFolder[name] ?? []
            return Folder(name: name, count: inside.count, bytes: inside.reduce(0) { $0 + $1.bytes })
        }
        selection.formIntersection(items.map(\.id))
        state = .ready
    }

    func items(in scope: Scope, deviceID: String? = nil, kind: Kind = .all) -> [MediaItem] {
        items.filter { item in
            if case .folder(let name) = scope, item.folder != name { return false }
            if let deviceID, item.deviceID != deviceID { return false }
            switch kind {
            case .all: return true
            case .photos: return !item.isVideo
            case .videos: return item.isVideo
            }
        }
    }

    /// The item as it is on its phone, if it was there at the last backup.
    func phoneAsset(_ item: MediaItem) -> PhoneAsset? {
        guard let deviceID = item.deviceID, let assetID = item.assetID else { return nil }
        return onPhone[deviceID]?[assetID]
    }

    // MARK: Organizing

    /// Moves items into a Folder, or back into their phone's folder when `folder` is nil.
    func move(_ items: [MediaItem], to folder: String?, server: BackupServer) async {
        let destination = folder.map { server.foldersURL.appending(path: $0, directoryHint: .isDirectory) }
        await perform(server) {
            for (deviceID, assets) in Dictionary(grouping: items.filter { $0.deviceID != nil }, by: { $0.deviceID! }) {
                guard let device = server.devices.first(where: { $0.id == deviceID }), let store = server.store(for: device) else { continue }
                try await store.move(assets.compactMap(\.assetID), to: destination)
            }
            guard let destination else { return }
            for item in items where item.deviceID == nil {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let target = Self.unusedURL(destination.appending(path: item.url.lastPathComponent))
                if target.deletingLastPathComponent().standardizedFileURL != item.url.deletingLastPathComponent().standardizedFileURL {
                    try FileManager.default.moveItem(at: item.url, to: target)
                }
            }
        }
    }

    /// Moves items to the Trash. Ones still on a phone aren't backed up from it again.
    func trash(_ items: [MediaItem], server: BackupServer) async {
        await perform(server) {
            for (deviceID, assets) in Dictionary(grouping: items.filter { $0.deviceID != nil }, by: { $0.deviceID! }) {
                guard let device = server.devices.first(where: { $0.id == deviceID }), let store = server.store(for: device) else { continue }
                try await store.trash(assets.compactMap(\.assetID))
            }
            for item in items where item.deviceID == nil {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            }
        }
    }

    /// Items the phone can be asked to remove: on it at its last backup, and fully backed up.
    func removable(_ items: [MediaItem]) -> [MediaItem] {
        items.filter { phoneAsset($0)?.isBackedUp == true && !pendingRemoval.contains($0.id) }
    }

    /// Queues the items for removal from their phones. Nothing happens there until it's confirmed on the phone.
    func removeFromPhone(_ items: [MediaItem], server: BackupServer) async {
        for (deviceID, removable) in Dictionary(grouping: removable(items), by: { $0.deviceID! }) {
            guard let device = server.devices.first(where: { $0.id == deviceID }) else { continue }
            server.request(.delete, for: removable.compactMap(phoneAsset), on: device)
        }
        pendingRemoval.formUnion(removable(items).map(\.id))
    }

    // MARK: Folders

    func createFolder(_ name: String, server: BackupServer) async -> String? {
        guard let name = Self.cleanName(name) else { return nil }
        await perform(server) {
            try FileManager.default.createDirectory(at: server.foldersURL.appending(path: name), withIntermediateDirectories: true)
        }
        return name
    }

    func renameFolder(_ folder: String, to name: String, server: BackupServer) async -> String? {
        guard let name = Self.cleanName(name), name != folder else { return nil }
        let old = server.foldersURL.appending(path: folder, directoryHint: .isDirectory)
        let new = server.foldersURL.appending(path: name, directoryHint: .isDirectory)
        await perform(server) {
            try FileManager.default.moveItem(at: old, to: new)
            for device in server.devices {
                await server.store(for: device)?.folderMoved(from: old, to: new)
            }
        }
        return name
    }

    /// Moves an empty Folder to the Trash.
    func deleteFolder(_ folder: String, server: BackupServer) async {
        await perform(server) {
            try FileManager.default.trashItem(at: server.foldersURL.appending(path: folder, directoryHint: .isDirectory), resultingItemURL: nil)
        }
    }

    // MARK: Helpers

    private func perform(_ server: BackupServer, _ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            self.error = error.localizedDescription
        }
        await load(from: server, force: true)
        await server.refreshSummaries()
    }

    nonisolated private static func folder(of url: URL, in foldersURL: URL) -> String? {
        let base = foldersURL.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > base.count + 1, Array(parts.prefix(base.count)) == base else { return nil }
        return parts[base.count]
    }

    nonisolated private static func folderNames(in foldersURL: URL) -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: foldersURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Photos and videos anywhere under the Folders.
    nonisolated private static func mediaFiles(in foldersURL: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentTypeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: foldersURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let type = values.contentType else { return false }
            return type.conforms(to: .image) || type.conforms(to: .movie)
        }.map(\.standardizedFileURL)
    }

    private static func fileItem(_ url: URL, in foldersURL: URL) -> MediaItem {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .creationDateKey])
        return MediaItem(
            id: url.path, url: url, name: url.lastPathComponent, date: values?.creationDate,
            isVideo: values?.contentType?.conforms(to: .movie) ?? false, duration: 0,
            bytes: UInt64(values?.fileSize ?? 0), folder: folder(of: url, in: foldersURL)
        )
    }

    /// "Tennis" stays "Tennis"; names Finder wouldn't accept are refused.
    private static func cleanName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return trimmed.isEmpty || trimmed.hasPrefix(".") ? nil : trimmed
    }

    private static func unusedURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let path = LibraryLayout.numbered(url.path, n)
            candidate = URL(filePath: path)
            n += 1
        }
        return candidate
    }
}
