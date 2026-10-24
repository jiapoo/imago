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
    /// Which of the user's folders it's in: "Tennis", "Tennis/Serve". Nil while it's in its phone's
    /// own folder, or in Recently Deleted.
    var folder: String?
    /// The phone it came from and its asset there. Nil for files that didn't come from a phone.
    var deviceID: String?
    var assetID: String?
}

/// An item in Recently Deleted, and where Put Back returns it.
struct TrashedItem: Identifiable, Hashable, Sendable {
    var item: MediaItem
    var deletedAt: Date
    var originalPlace: MediaLibrary.Place
    var id: String { item.id }

    /// Days before it's deleted for good, rounded up; nil when Recently Deleted keeps items until emptied.
    func daysLeft(keeping days: Int) -> Int? {
        guard days > 0 else { return nil }
        return max(0, Int((goneDate(keeping: days).timeIntervalSinceNow / 86_400).rounded(.up)))
    }

    /// Its time in Recently Deleted is up.
    func isExpired(keeping days: Int) -> Bool {
        days > 0 && goneDate(keeping: days) <= .now
    }

    private func goneDate(keeping days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: deletedAt) ?? deletedAt
    }
}

/// Everything in the backup library, across phones, the user's folders and Recently Deleted. Built from each
/// phone's index, so opening it doesn't read the whole drive; only the Folders and Recently Deleted
/// themselves are listed.
///
/// Every change is a move between places (an iPhone's own folder, a folder, Recently Deleted), and
/// returns the step that undoes it, for `FileHistory`.
@MainActor @Observable
final class MediaLibrary {
    /// Where the user's folders were before they moved to the top of the backup location.
    nonisolated static let legacyFoldersName = "Folders"

    enum State: Equatable { case loading, unavailable, ready }

    enum Scope: Hashable {
        case all
        /// A folder and the folders inside it.
        case folder(String)
        case trash
        /// The biggest items, biggest first.
        case large
    }

    enum Kind: String, CaseIterable, Identifiable {
        case all, photos, videos
        var id: Self { self }
    }

    /// Where an item can be.
    enum Place: Hashable, Codable, Sendable {
        /// Its iPhone's own dated folder.
        case phoneFolder
        /// One of the user's folders, by its path from the top of the backup location.
        case folder(String)
        case trash
    }

    /// One of the user's folders, with the folders inside it.
    struct Folder: Identifiable, Hashable {
        /// "Tennis/Serve".
        var path: String
        var count: Int
        var bytes: UInt64
        /// Nil when it has none, for outline lists.
        var children: [Folder]?
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }


    private(set) var state: State = .loading
    private(set) var items: [MediaItem] = []
    private(set) var trash: [TrashedItem] = []
    /// The top-level folders, each with the ones inside it.
    private(set) var folders: [Folder] = []
    /// What each phone had at its last backup: device ID → asset ID → asset.
    private(set) var onPhone: [String: [String: PhoneAsset]] = [:]
    /// Assets already queued for removal from their phone, as item IDs.
    private(set) var pendingRemoval: Set<String> = []
    /// Assets being checked against their checksums before their phone is asked to remove them.
    private(set) var verifying = 0
    /// Shared with the sidebar, so dropping one selected item on a Folder moves the whole selection.
    var selection: Set<MediaItem.ID> = []
    var error: String?

    private var loadedRevision: Int?

    /// Items over this size show in Large Files.
    static let largeFileBytes: UInt64 = 20_000_000

    // MARK: Reading

    func load(from server: BackupServer, force: Bool = false) async {
        guard force || loadedRevision != server.catalogRevision else { return }
        loadedRevision = server.catalogRevision
        guard server.location.isAvailable else {
            state = .unavailable
            items = []
            trash = []
            folders = []
            return
        }
        if items.isEmpty { state = .loading }

        await moveLegacyFolders(server)
        let foldersURL = server.foldersURL
        let trashURL = server.trashURL
        let reserved = server.reservedFolderNames
        let manifest = await Task.detached { TrashManifest.read(in: trashURL) }.value
        var loaded: [MediaItem] = []
        var trashed: [TrashedItem] = []
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
                var item = MediaItem(
                    id: "\(device.id)/\(entry.assetID)", url: display.url,
                    name: entry.metadata.originalFilename, date: entry.metadata.creationDate,
                    isVideo: entry.metadata.mediaType == "video", duration: entry.metadata.duration,
                    bytes: entry.files.reduce(0) { $0 + $1.size },
                    folder: Self.folderPath(of: display.url, in: foldersURL, reserved: reserved),
                    deviceID: device.id, assetID: entry.assetID
                )
                if Self.isInside(display.url, trashURL) {
                    item.folder = nil
                    let record = manifest.entries[item.id]
                    trashed.append(TrashedItem(item: item, deletedAt: record?.deletedAt ?? .now, originalPlace: record?.from ?? .phoneFolder))
                } else {
                    loaded.append(item)
                }
            }
            if let library = await store.phoneLibrary() {
                phones[device.id] = Dictionary(library.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
            for change in await store.changeQueue().pending where change.action == .delete {
                pending.formUnion(change.assetIDs.map { "\(device.id)/\($0)" })
            }
        }

        // Files in Folders or Recently Deleted that no phone's index knows: added another way, or moved
        // there in Finder. Listing them reads the drive, which can take a while on a slow one, so it's
        // off the main thread.
        let (unknown, folderPaths) = await Task.detached(priority: .userInitiated) {
            let paths = Self.folderPaths(in: foldersURL, reserved: reserved)
            let tops = paths.filter { !$0.contains("/") }.map { foldersURL.appending(path: $0, directoryHint: .isDirectory) }
            return ((tops.flatMap(Self.mediaFiles(in:)) + Self.mediaFiles(in: trashURL)).filter { !known.contains($0) }, paths)
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
            } else if Self.isInside(url, trashURL) {
                let record = manifest.entries[TrashManifest.key(forFile: url)]
                trashed.append(TrashedItem(item: Self.fileItem(url, in: foldersURL, reserved: reserved, folder: nil),
                                           deletedAt: record?.deletedAt ?? .now, originalPlace: record?.from ?? .folder("")))
            } else {
                loaded.append(Self.fileItem(url, in: foldersURL, reserved: reserved))
            }
        }
        if relinked {
            // Moved in Finder: read again so they show up with their phone's details.
            await load(from: server, force: true)
            return
        }

        items = loaded.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        trash = trashed.sorted { $0.deletedAt > $1.deletedAt }
        onPhone = phones
        pendingRemoval = pending
        folders = Self.tree(folderPaths, items: items)
        selection.formIntersection(items.map(\.id) + trash.map(\.id))
        state = .ready

        // Past their days in Recently Deleted: gone for good.
        if server.trashDays > 0 {
            let expired = trash.filter { $0.isExpired(keeping: server.trashDays) }
            if !expired.isEmpty { await deleteNow(expired, server: server) }
        }
    }

    func items(in scope: Scope, deviceID: String? = nil, kind: Kind = .all) -> [MediaItem] {
        let source: [MediaItem] = switch scope {
        case .trash: trash.map(\.item)
        case .large: items.filter { $0.bytes >= Self.largeFileBytes }.sorted { $0.bytes > $1.bytes }
        default: items
        }
        return source.filter { item in
            if case .folder(let path) = scope {
                guard let folder = item.folder, folder == path || folder.hasPrefix(path + "/") else { return false }
            }
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

    func trashed(_ item: MediaItem) -> TrashedItem? {
        trash.first { $0.id == item.id }
    }

    /// Where an item is now.
    func place(of item: MediaItem) -> Place {
        if trash.contains(where: { $0.id == item.id }) { return .trash }
        if let folder = item.folder { return .folder(folder) }
        return item.deviceID != nil ? .phoneFolder : .folder("")
    }

    // MARK: Organizing

    /// Moves items into a folder, or back into their phone's folder for `.phoneFolder`. Returns the
    /// step that undoes it.
    func move(_ items: [MediaItem], to place: Place, server: BackupServer) async -> FileHistory.Step? {
        let name = switch place {
        case .phoneFolder: "Move Back to iPhone's Folder"
        case .folder(let path): "Move to “\((path as NSString).lastPathComponent)”"
        case .trash: items.count == 1 ? "Delete" : "Delete \(items.count) Items"
        }
        return await moveStep(items.map { (Self.ref($0), place) }, name: name, server: server)
    }

    /// Moves items to Recently Deleted. Ones still on a phone aren't backed up from it again.
    func trash(_ items: [MediaItem], server: BackupServer) async -> FileHistory.Step? {
        await move(items, to: .trash, server: server)
    }

    /// Returns items from Recently Deleted to where they were deleted from.
    func putBack(_ items: [TrashedItem], server: BackupServer) async -> FileHistory.Step? {
        await moveStep(items.map { (Self.ref($0.item), $0.originalPlace) },
                       name: items.count == 1 ? "Put Back" : "Put Back \(items.count) Items", server: server)
    }

    /// Deletes items in Recently Deleted for good. This can't be undone.
    func deleteNow(_ items: [TrashedItem], server: BackupServer) async {
        let trashURL = server.trashURL
        await perform(server) {
            for (deviceID, assets) in Dictionary(grouping: items.map(\.item).filter { $0.deviceID != nil }, by: { $0.deviceID! }) {
                guard let device = server.devices.first(where: { $0.id == deviceID }), let store = server.store(for: device) else { continue }
                try await store.deletePermanently(assets.compactMap(\.assetID))
            }
            for item in items.map(\.item) where item.deviceID == nil {
                try FileManager.default.removeItem(at: item.url)
            }
            await Task.detached {
                var manifest = TrashManifest.read(in: trashURL)
                for item in items.map(\.item) { manifest.entries[TrashManifest.key(for: item)] = nil }
                manifest.write(in: trashURL)
            }.value
        }
    }

    /// Runs the moves, then returns the step that runs them backwards (which returns this one again).
    private func moveStep(_ moves: [(ItemRef, Place)], name: String, server: BackupServer) async -> FileHistory.Step? {
        let done = await moveRefs(moves, server: server)
        guard !done.isEmpty else { return nil }
        return FileHistory.Step(name: name) { [weak self] in
            await self?.moveStep(done.map { ($0.ref, $0.from) }, name: name, server: server)
        }
    }

    /// An item as a move can find it again: a phone's asset by its ID, any other file by its place.
    enum ItemRef: Hashable, Sendable {
        case asset(deviceID: String, assetID: String)
        case file(URL)
    }

    private static func ref(_ item: MediaItem) -> ItemRef {
        if let deviceID = item.deviceID, let assetID = item.assetID { return .asset(deviceID: deviceID, assetID: assetID) }
        return .file(item.url)
    }

    private func item(for ref: ItemRef) -> MediaItem? {
        switch ref {
        case .asset(let deviceID, let assetID):
            let id = "\(deviceID)/\(assetID)"
            return items.first { $0.id == id } ?? trash.first { $0.id == id }?.item
        case .file(let url):
            let url = url.lexicallyStandardized
            return items.first { $0.url.lexicallyStandardized == url } ?? trash.first { $0.item.url.lexicallyStandardized == url }?.item
        }
    }

    /// Moves each item to its place. Returns what moved: each item as it can be found now, and where
    /// it was before.
    private func moveRefs(_ moves: [(ItemRef, Place)], server: BackupServer) async -> [(ref: ItemRef, from: Place)] {
        let foldersURL = server.foldersURL
        let trashURL = server.trashURL
        func directory(_ place: Place) -> URL? {
            switch place {
            case .phoneFolder: nil
            case .folder(let path): path.isEmpty ? foldersURL : foldersURL.appending(path: path, directoryHint: .isDirectory)
            case .trash: trashURL
            }
        }
        var done: [(ref: ItemRef, from: Place)] = []
        var deleted: [String: TrashManifest.Entry] = [:]
        var restored: [String] = []
        let wanted: [(item: MediaItem, from: Place, to: Place)] = moves.compactMap { ref, to in
            guard let item = item(for: ref) else { return nil }
            let from = place(of: item)
            // Only phone assets have a phone folder to go back to.
            guard from != to, !(to == .phoneFolder && item.deviceID == nil) else { return nil }
            return (item, from, to)
        }
        // Each moved item as it was, and how to find it now.
        var moved: [(was: MediaItem, now: ItemRef)] = []
        defer {
            // Thumbnails follow their files, so moved items don't make them again from the drive.
            for (was, ref) in moved {
                guard let now = item(for: ref) else { continue }
                Thumbnails.shared.carryOver(from: was.url, to: now.url, bytes: was.bytes)
            }
        }
        await perform(server) {
            let phoneMoves = wanted.filter { $0.item.deviceID != nil }
            for (key, group) in Dictionary(grouping: phoneMoves, by: { "\($0.item.deviceID!)|\(String(describing: $0.to))" }) {
                guard let deviceID = key.split(separator: "|").first.map(String.init),
                      let device = server.devices.first(where: { $0.id == deviceID }), let store = server.store(for: device),
                      let to = group.first?.to else { continue }
                if let target = directory(to) { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true) }
                try await store.move(group.compactMap(\.item.assetID), to: directory(to))
                for move in group {
                    done.append((Self.ref(move.item), move.from))
                    moved.append((move.item, Self.ref(move.item)))
                }
            }
            for move in wanted where move.item.deviceID == nil {
                guard let target = directory(move.to) else { continue }
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let destination = Self.unusedURL(target.appending(path: move.item.url.lastPathComponent))
                try FileManager.default.moveItem(at: move.item.url, to: destination)
                done.append((.file(destination.lexicallyStandardized), move.from))
                moved.append((move.item, .file(destination.lexicallyStandardized)))
                if move.to == .trash { deleted[TrashManifest.key(forFile: destination)] = .init(deletedAt: .now, from: move.from) }
                if move.from == .trash { restored.append(TrashManifest.key(forFile: move.item.url)) }
            }
            for move in phoneMoves {
                if move.to == .trash { deleted[move.item.id] = .init(deletedAt: .now, from: move.from) }
                if move.from == .trash { restored.append(move.item.id) }
            }
            if !deleted.isEmpty || !restored.isEmpty {
                let (deleted, restored) = (deleted, restored)
                await Task.detached {
                    var manifest = TrashManifest.read(in: trashURL)
                    for key in restored { manifest.entries[key] = nil }
                    manifest.entries.merge(deleted) { _, new in new }
                    manifest.write(in: trashURL)
                }.value
            }
        }
        return done
    }

    /// Items the phone can be asked to remove: on it at its last backup, and fully backed up.
    func removable(_ items: [MediaItem]) -> [MediaItem] {
        items.filter { phoneAsset($0)?.isBackedUp == true && !pendingRemoval.contains($0.id) }
    }

    /// Asks the items' phones to remove them, once each file still matches the checksum it had when it
    /// arrived: after this, the backup may be the only copy. Nothing happens on a phone until it's
    /// confirmed there. Returns the step that withdraws the request.
    func removeFromPhone(_ items: [MediaItem], server: BackupServer) async -> FileHistory.Step? {
        var requested: [(device: PairedDevice, assets: [PhoneAsset])] = []
        var failed = 0
        for (deviceID, removable) in Dictionary(grouping: removable(items), by: { $0.deviceID! }) {
            guard let device = server.devices.first(where: { $0.id == deviceID }), let store = server.store(for: device) else { continue }
            let ids = removable.compactMap(\.assetID)
            verifying += ids.count
            let files = await store.storedFiles(of: ids)
            let verified = await Task.detached(priority: .userInitiated) {
                Set(files.filter { _, files in
                    !files.isEmpty && files.allSatisfy { (try? FileHasher.sha256(of: $0.url)) == $0.sha256 }
                }.keys)
            }.value
            verifying -= ids.count
            failed += ids.count - verified.count
            let assets = removable.filter { verified.contains($0.assetID ?? "") }.compactMap(phoneAsset)
            guard !assets.isEmpty else { continue }
            server.request(.delete, for: assets, on: device)
            pendingRemoval.formUnion(assets.map { "\(deviceID)/\($0.id)" })
            requested.append((device, assets))
        }
        if failed > 0 {
            error = "\(failed) \(failed == 1 ? "item doesn't" : "items don't") match the copy that was backed up, so \(failed == 1 ? "it stays" : "they stay") on the iPhone. Back up again to replace the copy here."
        }
        guard !requested.isEmpty else { return nil }
        let count = requested.reduce(0) { $0 + $1.assets.count }
        return FileHistory.Step(name: count == 1 ? "Remove from iPhone" : "Remove \(count) Items from iPhone") { [weak self] in
            for request in requested { server.keep(Set(request.assets.map(\.id)), on: request.device) }
            self?.pendingRemoval.subtract(requested.flatMap { request in request.assets.map { "\(request.device.id)/\($0.id)" } })
            return FileHistory.Step(name: "Remove from iPhone") { [weak self] in
                await self?.removeFromPhone(items, server: server)
            }
        }
    }

    // MARK: Folders

    /// Makes a folder, inside `parent` or at the top of Folders. Returns its path and the step that
    /// removes it again.
    func createFolder(_ name: String, in parent: String? = nil, server: BackupServer) async -> (path: String, undo: FileHistory.Step?)? {
        guard let name = Self.cleanName(name) else { return nil }
        let path = parent.map { $0.isEmpty ? name : "\($0)/\(name)" } ?? name
        let url = server.foldersURL.appending(path: path, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: url.path), !server.reservedFolderNames.contains(path) else { return (path, nil) }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
        await reloadFolders(server)
        return (path, removeFolderStep(path, server: server))
    }

    private func removeFolderStep(_ path: String, server: BackupServer) -> FileHistory.Step {
        FileHistory.Step(name: "New Folder") { [weak self] in
            guard let self, await self.deleteFolder(path, server: server) != nil else { return nil }
            let parent = (path as NSString).deletingLastPathComponent
            return await self.createFolder((path as NSString).lastPathComponent, in: parent, server: server)?.undo
        }
    }

    /// Renames a folder. Returns its new path and the step that renames it back.
    func renameFolder(_ path: String, to name: String, server: BackupServer) async -> (path: String, undo: FileHistory.Step?)? {
        guard let name = Self.cleanName(name), name != (path as NSString).lastPathComponent else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        let newPath = parent.isEmpty ? name : "\(parent)/\(name)"
        let old = server.foldersURL.appending(path: path, directoryHint: .isDirectory)
        let new = server.foldersURL.appending(path: newPath, directoryHint: .isDirectory)
        var renamed = false
        await perform(server) {
            try FileManager.default.moveItem(at: old, to: new)
            for device in server.devices {
                await server.store(for: device)?.folderMoved(from: old, to: new)
            }
            renamed = true
        }
        guard renamed else { return nil }
        let oldName = (path as NSString).lastPathComponent
        return (newPath, FileHistory.Step(name: "Rename Folder") { [weak self] in
            await self?.renameFolder(newPath, to: oldName, server: server)?.undo
        })
    }

    /// Removes an empty folder. Returns the step that makes it again.
    @discardableResult
    func deleteFolder(_ path: String, server: BackupServer) async -> FileHistory.Step? {
        let url = server.foldersURL.appending(path: path, directoryHint: .isDirectory)
        let left = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        guard left.isEmpty else {
            error = "“\((path as NSString).lastPathComponent)” isn't empty."
            return nil
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
        await reloadFolders(server)
        return FileHistory.Step(name: "Delete Folder") { [weak self] in
            let parent = (path as NSString).deletingLastPathComponent
            guard let made = await self?.createFolder((path as NSString).lastPathComponent, in: parent, server: server) else { return nil }
            return FileHistory.Step(name: "Delete Folder") { [weak self] in await self?.deleteFolder(made.path, server: server) }
        }
    }

    /// Copies items' files into a folder (an iPhone item's backed-up original, or the file itself),
    /// leaving the items where they are. Returns the step that removes the copies.
    func copy(_ items: [MediaItem], toFolder path: String, server: BackupServer) async -> FileHistory.Step? {
        guard let step = await copyIn(items.map(\.url), to: path, server: server) else { return nil }
        return step
    }

    /// Lists the folders again, without reading the phones' indexes: enough after making, renaming
    /// an empty or deleting a folder, and quick on a slow drive.
    func reloadFolders(_ server: BackupServer) async {
        let root = server.foldersURL
        let reserved = server.reservedFolderNames
        let paths = await Task.detached(priority: .userInitiated) { Self.folderPaths(in: root, reserved: reserved) }.value
        folders = Self.tree(paths, items: items)
    }

    /// Moves the user's folders out of the old `Folders/` to the top of the backup location, telling
    /// each phone's index where its files went. `Folders` goes when it's empty.
    private func moveLegacyFolders(_ server: BackupServer) async {
        let legacy = server.location.url.appending(path: Self.legacyFoldersName, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: legacy.path),
              !server.reservedFolderNames.contains(Self.legacyFoldersName) else { return }
        let children = (try? FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            var target = server.location.url.appending(path: child.lastPathComponent, directoryHint: .isDirectory)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) || server.reservedFolderNames.contains(target.lastPathComponent) {
                target = server.location.url.appending(path: "\(child.lastPathComponent) \(n)", directoryHint: .isDirectory)
                n += 1
            }
            guard (try? FileManager.default.moveItem(at: child, to: target)) != nil else { continue }
            for device in server.devices { await server.store(for: device)?.folderMoved(from: child, to: target) }
        }
        let left = (try? FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        if left.isEmpty { try? FileManager.default.removeItem(at: legacy) }
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

    nonisolated private static func isInside(_ url: URL, _ directory: URL) -> Bool {
        let base = directory.lexicallyStandardized.pathComponents
        let parts = url.lexicallyStandardized.pathComponents
        return parts.count > base.count && Array(parts.prefix(base.count)) == base
    }

    /// The user's folder a file is in, as a path from the top of the backup location; nil when it's
    /// in a phone's folder or Recently Deleted (`reserved`), or not in a folder at all.
    nonisolated private static func folderPath(of url: URL, in root: URL, reserved: Set<String>) -> String? {
        let base = root.lexicallyStandardized.pathComponents
        let parts = url.lexicallyStandardized.pathComponents
        guard parts.count > base.count + 1, Array(parts.prefix(base.count)) == base,
              !reserved.contains(parts[base.count]), !parts[base.count].hasPrefix(".") else { return nil }
        return parts[base.count..<(parts.count - 1)].joined(separator: "/")
    }

    /// Every one of the user's folders, as paths from the top of the backup location, parents before
    /// children. The phones' folders and Recently Deleted (`reserved`) aren't looked into.
    nonisolated private static func folderPaths(in root: URL, reserved: Set<String>) -> [String] {
        let tops = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles]
        )) ?? []).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true
                && !reserved.contains(url.lastPathComponent)
        }
        let base = root.lexicallyStandardized.pathComponents
        var paths: [String] = []
        for top in tops {
            paths.append(top.lastPathComponent)
            guard let enumerator = FileManager.default.enumerator(
                at: top, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                paths.append(Array(url.lexicallyStandardized.pathComponents.dropFirst(base.count)).joined(separator: "/"))
            }
        }
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Folders as a tree, each counting the items in it and the folders inside it.
    private static func tree(_ paths: [String], items: [MediaItem]) -> [Folder] {
        var counts: [String: (count: Int, bytes: UInt64)] = [:]
        for item in items {
            guard var folder = item.folder, !folder.isEmpty else { continue }
            while true {
                counts[folder, default: (0, 0)].count += 1
                counts[folder, default: (0, 0)].bytes += item.bytes
                let parent = (folder as NSString).deletingLastPathComponent
                if parent.isEmpty { break }
                folder = parent
            }
        }
        func children(of parent: String) -> [Folder] {
            paths.filter { ($0 as NSString).deletingLastPathComponent == parent }.map { path in
                let inside = children(of: path)
                return Folder(path: path, count: counts[path]?.count ?? 0, bytes: counts[path]?.bytes ?? 0,
                              children: inside.isEmpty ? nil : inside)
            }
        }
        return children(of: "")
    }

    /// Photos and videos anywhere under `directory`.
    nonisolated private static func mediaFiles(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentTypeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let type = values.contentType else { return false }
            return type.conforms(to: .image) || type.conforms(to: .movie)
        }.map(\.lexicallyStandardized)
    }

    private static func fileItem(_ url: URL, in foldersURL: URL, reserved: Set<String>, folder: String?? = .none) -> MediaItem {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .creationDateKey])
        return MediaItem(
            id: url.path, url: url, name: url.lastPathComponent, date: values?.creationDate,
            isVideo: values?.contentType?.conforms(to: .movie) ?? false, duration: 0,
            bytes: UInt64(values?.fileSize ?? 0), folder: folder ?? folderPath(of: url, in: foldersURL, reserved: reserved)
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

/// Where each item in Recently Deleted came from and when, so Put Back works after a restart. A hidden
/// file in the Recently Deleted folder, so it travels with it.
struct TrashManifest: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var deletedAt: Date
        var from: MediaLibrary.Place
    }

    /// By item ID for phone assets ("deviceID/assetID"), by file name for other files.
    var entries: [String: Entry] = [:]

    static func key(for item: MediaItem) -> String {
        item.deviceID != nil ? item.id : key(forFile: item.url)
    }

    static func key(forFile url: URL) -> String {
        "file:" + url.lastPathComponent
    }

    private static func url(in directory: URL) -> URL {
        directory.appending(path: ".imago-trash.json")
    }

    static func read(in directory: URL) -> TrashManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(TrashManifest.self, from: Data(contentsOf: url(in: directory)))) ?? TrashManifest()
    }

    func write(in directory: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: Self.url(in: directory), options: .atomic)
    }
}
