import AppKit
import ImagoKit
import SwiftUI
import Synchronization
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
    /// Where it was taken, when the iPhone knew.
    var latitude: Double? = nil
    var longitude: Double? = nil
    /// An iPhone item's shown file, as it arrived: to find copies of it in the folders.
    var original: FolderCopies.Fingerprint? = nil
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
        /// Backed up from this iPhone (by device ID) and still in its folder, but no longer on it.
        case deletedOnPhone(String)
        /// Taken on today's date in earlier years.
        case onThisDay
        /// Just these, by item ID (e.g. a place on the map).
        case items([String])
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
    /// Bumped whenever what's in the library changes (items, Recently Deleted, what's on the iPhones),
    /// so views can keep what they work out from it until then.
    private(set) var revision = 0
    private(set) var trash: [TrashedItem] = []
    /// The top-level folders, each with the ones inside it.
    private(set) var folders: [Folder] = []
    /// What each phone had at its last backup: device ID → asset ID → asset.
    private(set) var onPhone: [String: [String: PhoneAsset]] = [:]
    /// Assets already queued for removal from their phone, as item IDs.
    private(set) var pendingRemoval: Set<String> = []
    /// Assets being checked against their checksums before their phone is asked to remove them.
    private(set) var verifying = 0

    /// Something long under way (copying, moving, checking, deleting), for the progress panel.
    struct Activity: Equatable {
        var title: String
        /// The file being worked on.
        var detail: String?
        var done: Int
        var total: Int
        /// For one big file: bytes so far, and its size.
        var bytes: (done: UInt64, total: UInt64)?
        /// The work is done and the library is catching up: no way to tell how far, so the ring just turns.
        var finishing = false

        var fraction: Double {
            guard total > 0 else { return 0 }
            let part = bytes.map { $0.total > 0 ? Double($0.done) / Double($0.total) : 0 } ?? 0
            return min(1, (Double(done) + part) / Double(total))
        }

        static func == (a: Activity, b: Activity) -> Bool {
            a.title == b.title && a.detail == b.detail && a.done == b.done && a.total == b.total
                && a.bytes?.done == b.bytes?.done && a.bytes?.total == b.bytes?.total && a.finishing == b.finishing
        }
    }

    var activity: Activity?
    /// Files about to go into a folder that already has identical ones: what to do, asked in the window.
    var duplicateQuestion: DuplicateQuestion?
    /// When Imago first saw each item missing from its iPhone (by item ID): Deleted on iPhone moves it
    /// to Recently Deleted after as many days as Recently Deleted keeps things.
    private(set) var leftPhoneAt: [String: Date] = [:]
    /// Deleted on an iPhone, and kept here on purpose (Keep Backups): no longer on Deleted on iPhone,
    /// and never moved to Recently Deleted for it. By item ID, in the library's `.photobackup`.
    private(set) var kept: Set<String> = []
    /// Where `kept` and `leftPhoneAt` were read from. Only Imago writes them, so each is read once a
    /// location and kept here after; reading them off the drive on every library read took a third of
    /// a second each.
    private var keptReadFrom: URL?
    private var leftPhoneReadFrom: URL?
    /// Deleted on an iPhone and waiting to be put back there (a `restore` change), by item ID.
    private(set) var restoring: Set<String> = []
    /// Changes an iPhone turned down that the user hasn't decided about yet.
    private(set) var declines: [Decline] = []

    /// A change an iPhone said no to, waiting for a decision here.
    struct Decline: Identifiable {
        let device: PairedDevice
        let done: ChangeQueue.Done
        var id: UUID { done.id }
        var change: LibraryChange { done.change }
    }
    /// Shared with the sidebar, so dropping one selected item on a Folder moves the whole selection.
    var selection: Set<MediaItem.ID> = []
    var error: String?

    /// A quiet re-read is under way (`refreshQuietly`): pages say "Updating".
    private(set) var isRefreshing = false
    private var loadedRevision: Int?
    /// Bumped by each read of the library and each change shown straight away: a read that finds it
    /// changed since it began is out of date, and drops what it read.
    private var loadGeneration = 0
    /// A full re-read of the library after work that already updated what's on screen; see `refreshQuietly`.
    private var quietRefresh: Task<Void, Never>?
    /// The read under way. Reads take turns: one asked for meanwhile waits, then runs once more
    /// (`loadAgain`), however many asked. Several at once read every index and walk the drive side by
    /// side, each slower for the others.
    private var loading: Task<Void, Never>?
    private var loadAgain = false
    /// For each iPhone item (by ID), the folders it's in: its own backup moved into one, or the same
    /// file copied into it. See `findFolderCopies`.
    private(set) var inFolders: [String: [FolderCopies.Copy]] = [:]
    private var folderCopySearch: Task<Void, Never>?
    /// Not synced files being handed to an iPhone, so they're sent once.
    private var sendingPaths: Set<String> = []
    /// Each iPhone's library list as last read, and what it was read from (the list's date and how many
    /// files were stored). Reading a big one takes a while, and most reloads (a move, a put-back) don't
    /// change it.
    private var phoneCache: [String: (stamp: String, assets: [String: PhoneAsset])] = [:]
    /// Each iPhone's items as built from its index, with every file the index knows, by the version of
    /// the index they came from (see `BackupStore.versionedCatalog`).
    private var catalogItems: [String: (key: CatalogKey, items: CatalogItems)] = [:]

    private struct CatalogKey: Equatable {
        var store: ObjectIdentifier
        var version: Int
        var foldersURL: URL
        var trashURL: URL
    }

    private struct CatalogItems: Sendable {
        var items: [MediaItem]
        /// In Recently Deleted, with no folder.
        var trashed: [MediaItem]
        var files: Set<URL>
    }

    /// Hears about changes on the drive made outside Imago (see `DriveWatcher`, `reconcile`).
    private var watcher: DriveWatcher?
    /// Folders the watcher said changed, waiting for `reconcile`.
    private var changedFolders: Set<URL> = []
    /// The watcher lost track of what changed: the library is read again instead.
    private var changedBelow = false
    private var reconciling: Task<Void, Never>?
    /// File work under way here (moves, copies). Changes on the drive wait until it's done and shown,
    /// so its files aren't taken for new ones.
    private var working = 0

    /// Each iPhone's own folder → its device ID, for `waitingFor`.
    private(set) var phoneFolderOwners: [String: String] = [:]
    /// `deletedOnPhone` for each iPhone, as of a revision.
    @ObservationIgnored private var deletedOnPhoneCache: (revision: Int, byDevice: [String: [MediaItem]])?
    /// `items(in: .large)`, as of a revision.
    @ObservationIgnored private var largeCache: (revision: Int, items: [MediaItem])?

    private var durationFill: Task<Void, Never>?

    /// Items over this size show in Large Files.
    static let largeFileBytes: UInt64 = 20_000_000

    // MARK: Reading

    func load(from server: BackupServer, force: Bool = false) async {
        server.mediaLibrary = self
        watch(server)
        guard force || loadedRevision != server.catalogRevision else { return }
        loadedRevision = server.catalogRevision
        if let loading {
            loadAgain = true
            await loading.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                loadAgain = false
                await loadOnce(from: server)
            } while loadAgain
            // With nothing awaited since the check above, a read asked for now starts afresh.
            loading = nil
        }
        loading = task
        await task.value
    }

    /// One read of the whole library. Only `load` calls it; a reason to read again inside it sets
    /// `loadAgain` (awaiting `load` here would wait for itself).
    private func loadOnce(from server: BackupServer) async {
        guard server.location.isAvailable else {
            state = .unavailable
            items = []
            trash = []
            folders = []
            revision += 1
            return
        }
        if items.isEmpty { state = .loading }
        loadGeneration += 1
        let generation = loadGeneration

        await moveLegacyFolders(server)
        let foldersURL = server.foldersURL
        let trashURL = server.trashURL
        let reserved = server.reservedFolderNames
        let manifest = await Task.detached(priority: .userInitiated) { TrashManifest.read(in: trashURL) }.value
        var loaded: [MediaItem] = []
        var trashed: [TrashedItem] = []
        var phones: [String: [String: PhoneAsset]] = [:]
        var pending: Set<String> = []
        var putBack: Set<String> = []
        var turnedDown: [Decline] = []
        var stores: [BackupStore] = []
        var known: [Set<URL>] = []
        for device in server.devices {
            guard let store = server.store(for: device) else { continue }
            stores.append(store)
            let (version, entries) = await store.versionedCatalog()
            // Built once for each version of the iPhone's index, away from the main thread: tens of
            // thousands of items, and most reads (a copy into a folder, an undone one) don't change it.
            let key = CatalogKey(store: ObjectIdentifier(store), version: version, foldersURL: foldersURL, trashURL: trashURL)
            let built: CatalogItems
            if let cached = catalogItems[device.id], cached.key == key {
                built = cached.items
            } else {
                let deviceID = device.id
                built = await Task.detached(priority: .userInitiated) {
                    Self.items(from: entries, deviceID: deviceID, foldersURL: foldersURL, trashURL: trashURL, reserved: reserved)
                }.value
                catalogItems[device.id] = (key, built)
            }
            known.append(built.files)
            loaded += built.items
            trashed += built.trashed.map { item in
                let record = manifest.entries[item.id]
                return TrashedItem(item: item, deletedAt: record?.deletedAt ?? .now, originalPlace: record?.from ?? .phoneFolder)
            }
            // After the catalog, which finds the sidecars of records that didn't know theirs.
            await store.hideOlderSidecars()
            let stamp = "\(await store.snapshotModified()?.timeIntervalSince1970 ?? 0)|\(await store.resourceCount())"
            if let cached = phoneCache[device.id], cached.stamp == stamp {
                phones[device.id] = cached.assets
            } else if let library = await store.phoneLibrary() {
                let assets = Dictionary(library.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                phones[device.id] = assets
                phoneCache[device.id] = (stamp, assets)
            }
            let queue = await store.changeQueue()
            for change in queue.pending {
                if change.action == .delete { pending.formUnion(change.assetIDs.map { "\(device.id)/\($0)" }) }
                if change.action == .restore { putBack.formUnion(change.assetIDs.map { "\(device.id)/\($0)" }) }
            }
            turnedDown += queue.done.filter { $0.report.outcome == .declined && $0.resolution == nil }
                .map { Decline(device: device, done: $0) }
        }

        // Files in Folders or Recently Deleted that no phone's index knows: added another way, or moved
        // there in Finder. Listing them reads the drive, which can take a while on a slow one, so it's
        // off the main thread.
        // An iPhone's own folder too: an edited copy saved beside its original.
        let phoneFolders = server.devices.map { foldersURL.appending(path: $0.folder, directoryHint: .isDirectory) }
        let (unknown, folderPaths) = await Task.detached(priority: .userInitiated) {
            let paths = Self.folderPaths(in: foldersURL, reserved: reserved)
            let tops = paths.filter { !$0.contains("/") }.map { foldersURL.appending(path: $0, directoryHint: .isDirectory) }
            let files = (tops + phoneFolders).flatMap(Self.mediaFiles(in:)) + Self.mediaFiles(in: trashURL)
            DriveScan.shared.save()
            return (files.filter { file in !known.contains { $0.contains(file) } }, paths)
        }.value
        // Moved in Finder: each iPhone's index looks for its lost files among them, all at once.
        var claimed: Set<URL> = []
        for store in stores {
            claimed.formUnion(await store.relink(unknown.filter { !claimed.contains($0) }))
        }
        let relinked = !claimed.isEmpty
        // Each file's size, type and date come off the drive: away from the main thread.
        let remaining = unknown.filter { !claimed.contains($0) }
        let (files, trashedFiles) = await Task.detached(priority: .userInitiated) { () -> ([MediaItem], [TrashedItem]) in
            var files: [MediaItem] = []
            var trashedFiles: [TrashedItem] = []
            for url in remaining {
                if Self.isInside(url, trashURL) {
                    let record = manifest.entries[TrashManifest.key(forFile: url)]
                    trashedFiles.append(TrashedItem(item: Self.fileItem(url, in: foldersURL, reserved: reserved, folder: nil),
                                                    deletedAt: record?.deletedAt ?? .now, originalPlace: record?.from ?? .folder("")))
                } else {
                    files.append(Self.fileItem(url, in: foldersURL, reserved: reserved))
                }
            }
            return (files, trashedFiles)
        }.value
        loaded += files
        trashed += trashedFiles
        // Tens of thousands of items: sorted away from the main thread.
        let (sortedItems, sortedTrash) = await Task.detached(priority: .userInitiated) { [loaded, trashed] in
            (loaded.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }, trashed.sorted { $0.deletedAt > $1.deletedAt })
        }.value
        // Something changed on screen meanwhile (a move): this read is out of date. The re-read that
        // change asked for follows.
        guard generation == loadGeneration else { return }
        if relinked {
            // Moved in Finder: read again so they show up with their phone's details.
            loadAgain = true
            return
        }

        items = sortedItems
        trash = sortedTrash
        phoneFolderOwners = Dictionary(server.devices.map { ($0.folder, $0.id) }, uniquingKeysWith: { a, _ in a })
        onPhone = phones
        pendingRemoval = pending
        restoring = putBack
        declines = turnedDown
        if keptReadFrom != keptURL(server) {
            kept = await Self.readKept(at: keptURL(server))
            keptReadFrom = keptURL(server)
        }
        revision += 1
        folders = Self.tree(folderPaths, items: items)
        selection.formIntersection(items.map(\.id) + trash.map(\.id))
        state = .ready
        findFolderCopies(server)
        fillDurations()
        // Sent and now the iPhone's (or gone): no longer waiting to be sent.
        sendingPaths.formIntersection(server.devices.flatMap { notSynced(on: $0) }.map(\.url.path))
        sendNotSynced(server)

        // Deleted on an iPhone: note when each was first seen missing, and after its days, move it to
        // Recently Deleted (where it gets the same days again before it's gone for good).
        await noteLeftPhone(server)
        // Answers that settle themselves: a deletion turned down the second time it was asked keeps the
        // backups; a put-back turned down keeps them too, off the iPhone.
        if await settleFinalAnswers(server) {
            loadAgain = true
            return
        }
        if await moveDeletedOnPhone(server) { return }

        // Past their days in Recently Deleted: gone for good.
        if server.trashDays > 0 {
            let expired = trash.filter { $0.isExpired(keeping: server.trashDays) }
            if !expired.isEmpty { await deleteNow(expired, server: server) }
        }
    }

    /// Some of an iPhone's assets changed in its index (sent to it, taken back, put back under new IDs):
    /// just those are read again, not the whole library. `files`: files on the drive that may have
    /// become one of its assets (they leave the page as plain files), or stopped being one (they come
    /// back as plain files, if they're still there).
    func assetsChanged(_ assetIDs: Set<String>, files: [URL], on device: PairedDevice, server: BackupServer) async {
        guard state == .ready, let store = server.store(for: device) else {
            // A read under way may have begun before the change: it runs once more.
            if loading != nil { loadAgain = true }
            return
        }
        let foldersURL = server.foldersURL
        let trashURL = server.trashURL
        let reserved = server.reservedFolderNames
        let deviceID = device.id
        let entries = await store.catalogEntries(of: assetIDs)
        let (built, manifest, plain) = await Task.detached(priority: .userInitiated) {
            let built = Self.items(from: entries, deviceID: deviceID, foldersURL: foldersURL, trashURL: trashURL, reserved: reserved)
            let held = Set(built.files.map(\.lexicallyStandardized.path))
            let plain = files.map(\.lexicallyStandardized)
                .filter { !held.contains($0.path) && FileManager.default.fileExists(atPath: $0.path) }
                .map { Self.fileItem($0, in: foldersURL, reserved: reserved) }
            return (built, TrashManifest.read(in: trashURL), plain)
        }.value

        let ids = Set(assetIDs.map { "\(deviceID)/\($0)" })
        let paths = Set((files + built.files).map(\.lexicallyStandardized.path))
        func leaving(_ item: MediaItem) -> Bool {
            ids.contains(item.id) || (item.deviceID == nil && paths.contains(item.url.path))
        }
        items.removeAll(where: leaving)
        trash.removeAll { leaving($0.item) }
        // Still plain files elsewhere on the page (another iPhone's index may hold them): not twice.
        // Items' files are kept standardized already, so their paths are compared as they are.
        let wanted = Set(plain.map(\.url.path))
        let shown = wanted.isEmpty ? [] : Set((items.lazy.map(\.url.path) + trash.lazy.map(\.item.url.path)).filter(wanted.contains))
        items += built.items
        items += plain.filter { !Self.isInside($0.url, trashURL) && !shown.contains($0.url.path) }
        trash += built.trashed.map { item in
            let record = manifest.entries[item.id]
            return TrashedItem(item: item, deletedAt: record?.deletedAt ?? .now, originalPlace: record?.from ?? .phoneFolder)
        }
        trash += plain.filter { Self.isInside($0.url, trashURL) && !shown.contains($0.url.path) }.map { item in
            var item = item
            item.folder = nil
            let record = manifest.entries[TrashManifest.key(forFile: item.url)]
            return TrashedItem(item: item, deletedAt: record?.deletedAt ?? .now, originalPlace: record?.from ?? .folder(""))
        }
        items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        trash.sort { $0.deletedAt > $1.deletedAt }
        selection.formIntersection(items.map(\.id) + trash.map(\.id))
        folders = folderTree()
        sendingPaths.formIntersection(server.devices.flatMap { notSynced(on: $0) }.map(\.url.path))
        changedHere()
        findFolderCopies(server)
        fillDurations()
    }

    /// Large Files, worked out once per change: Home shows its count on every redraw.
    private func largeItems() -> [MediaItem] {
        if largeCache?.revision != revision {
            largeCache = (revision, items.filter { $0.bytes >= Self.largeFileBytes }.sorted { $0.bytes > $1.bytes })
        }
        return largeCache?.items ?? []
    }

    /// Changes from the iPhones made automatically: deleted there, so to Recently Deleted here now (or
    /// once its days are up). Returns whether anything moved.
    private func moveDeletedOnPhone(_ server: BackupServer) async -> Bool {
        guard server.acceptPhoneChanges || server.trashDays > 0 else { return false }
        let due = server.devices.flatMap { deletedOnPhone($0.id) }
            .filter { !restoring.contains($0.id)
                && (server.acceptPhoneChanges || (daysUntilMoved($0, keeping: server.trashDays) ?? 1) == 0) }
        guard !due.isEmpty else { return false }
        _ = await trash(due, server: server)
        return true
    }

    /// An iPhone's library list or its changes changed (over the live link): what's on it, what's
    /// waiting for it and what it turned down are read again, and what it deleted is noted, without
    /// reading the rest of the library.
    func phoneListChanged(_ device: PairedDevice, server: BackupServer) async {
        guard state == .ready, let store = server.store(for: device) else { return }
        let prefix = device.id + "/"
        let queue = await store.changeQueue()
        pendingRemoval = pendingRemoval.filter { !$0.hasPrefix(prefix) }
            .union(queue.pending.filter { $0.action == .delete }.flatMap { $0.assetIDs.map { prefix + $0 } })
        restoring = restoring.filter { !$0.hasPrefix(prefix) }
            .union(queue.pending.filter { $0.action == .restore }.flatMap { $0.assetIDs.map { prefix + $0 } })
        declines = declines.filter { $0.device.id != device.id }
            + queue.done.filter { $0.report.outcome == .declined && $0.resolution == nil }.map { Decline(device: device, done: $0) }
        let stamp = "\(await store.snapshotModified()?.timeIntervalSince1970 ?? 0)|\(await store.resourceCount())"
        if phoneCache[device.id]?.stamp != stamp, let library = await store.phoneLibrary() {
            let assets = Dictionary(library.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            phoneCache[device.id] = (stamp, assets)
            onPhone[device.id] = assets
        }
        changedHere()
        await noteLeftPhone(server)
        if await settleFinalAnswers(server) { return }
        _ = await moveDeletedOnPhone(server)
    }

    /// Days before an item on Deleted on iPhone moves to Recently Deleted, rounded up; nil when it isn't
    /// there or Recently Deleted keeps things until emptied.
    func daysUntilMoved(_ item: MediaItem, keeping days: Int) -> Int? {
        guard days > 0, let since = leftPhoneAt[item.id] else { return nil }
        let due = Calendar.current.date(byAdding: .day, value: days, to: since) ?? since
        return max(0, Int((due.timeIntervalSinceNow / 86_400).rounded(.up)))
    }

    // MARK: Answers from the iPhones

    /// Keeps the backups of a deletion the iPhone turned down: they come back from Recently Deleted
    /// to where they were, and both sides agree the photos stay. Returns the step that undoes it.
    func keepHereToo(_ decline: Decline, server: BackupServer) async -> FileHistory.Step? {
        let ids = Set(decline.change.assetIDs.map { "\(decline.device.id)/\($0)" })
        let back = trash.filter { ids.contains($0.id) }
        // Settled first, so the question goes at once; Put Back's own reload is the only one.
        await server.resolve(decline.change, as: .kept, on: decline.device)
        declines.removeAll { $0.id == decline.id }
        return back.isEmpty ? nil : await putBack(back, server: server)
    }

    /// Settles a turned-down change as it is: for a deletion, the backups stay in Recently Deleted and
    /// the photos stay on the iPhone; for anything else, it's just noted.
    func leaveAsIs(_ decline: Decline, server: BackupServer) async {
        await server.resolve(decline.change, as: decline.change.action == .delete ? .leftDeleted : .dismissed, on: decline.device)
        declines.removeAll { $0.id == decline.id }
    }

    /// Asks the iPhone once more. If it says no again, the backups are kept (see `settleFinalAnswers`).
    func askAgain(_ decline: Decline, server: BackupServer) async {
        server.askAgain(decline.change, on: decline.device)
        await server.resolve(decline.change, as: .askedAgain, on: decline.device)
        declines.removeAll { $0.id == decline.id }
        if decline.change.action == .delete {
            pendingRemoval.formUnion(decline.change.assetIDs.map { "\(decline.device.id)/\($0)" })
            revision += 1
        }
    }

    /// Keeps the backups of items deleted on their iPhone, on purpose: they leave Deleted on iPhone and
    /// stay where they are. Returns the step that undoes it.
    func keepBackups(_ items: [MediaItem], server: BackupServer) async -> FileHistory.Step? {
        let ids = Set(items.map(\.id)).subtracting(kept)
        guard !ids.isEmpty else { return nil }
        kept.formUnion(ids)
        await Self.writeKept(kept, to: keptURL(server))
        revision += 1
        return FileHistory.Step(name: ids.count == 1 ? "Keep Backup" : "Keep \(ids.count) Backups") { [weak self] in
            guard let self else { return nil }
            kept.subtract(ids)
            await Self.writeKept(kept, to: keptURL(server))
            revision += 1
            return FileHistory.Step(name: "Keep Backups") { [weak self] in await self?.keepBackups(items, server: server) }
        }
    }

    /// Asks the items' iPhones to put them back in their libraries, from the backups here. Each iPhone
    /// asks first, then fetches the files while Imago is open on it. Returns the step that withdraws it.
    func putBackOnPhone(_ items: [MediaItem], server: BackupServer) async -> FileHistory.Step? {
        var asked: [(PairedDevice, [String])] = []
        for (deviceID, group) in Dictionary(grouping: items.filter { $0.deviceID != nil && !restoring.contains($0.id) }, by: { $0.deviceID! }) {
            guard let device = server.devices.first(where: { $0.id == deviceID }) else { continue }
            let assetIDs = group.compactMap(\.assetID)
            server.requestRestore(assetIDs, on: device)
            asked.append((device, assetIDs))
        }
        guard !asked.isEmpty else { return nil }
        restoring.formUnion(asked.flatMap { device, ids in ids.map { "\(device.id)/\($0)" } })
        revision += 1
        let count = asked.reduce(0) { $0 + $1.1.count }
        return FileHistory.Step(name: count == 1 ? "Put Back on iPhone" : "Put Back \(count) Items on iPhone") { [weak self] in
            for (device, ids) in asked { server.withdrawRestore(Set(ids), on: device) }
            self?.restoring.subtract(asked.flatMap { device, ids in ids.map { "\(device.id)/\($0)" } })
            self?.revision += 1
            return FileHistory.Step(name: "Put Back on iPhone") { [weak self] in await self?.putBackOnPhone(items, server: server) }
        }
    }

    /// Settles turned-down changes that need no question: a deletion turned down when asked again keeps
    /// the backups (they come back from Recently Deleted), and so does a put-back the iPhone turned
    /// down (they stay here, off Deleted on iPhone). Returns whether anything changed.
    private func settleFinalAnswers(_ server: BackupServer) async -> Bool {
        var changed = false
        for decline in declines {
            switch decline.change.action {
            case .delete where decline.change.isAskedAgain:
                let ids = Set(decline.change.assetIDs.map { "\(decline.device.id)/\($0)" })
                let back = trash.filter { ids.contains($0.id) }
                if !back.isEmpty { _ = await putBack(back, server: server) }
                await server.resolve(decline.change, as: .kept, on: decline.device)
                changed = true
            case .restore:
                kept.formUnion(decline.change.assetIDs.map { "\(decline.device.id)/\($0)" })
                await Self.writeKept(kept, to: keptURL(server))
                await server.resolve(decline.change, as: .kept, on: decline.device)
                changed = true
            default:
                break
            }
        }
        return changed
    }

    private func keptURL(_ server: BackupServer) -> URL {
        server.location.url.appending(path: ".photobackup/kept-off-iphone.json")
    }

    private nonisolated static func readKept(at url: URL) async -> Set<String> {
        await Task.detached(priority: .userInitiated) { (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: url))) ?? [] }.value
    }

    private nonisolated static func writeKept(_ kept: Set<String>, to url: URL) async {
        await Task.detached {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(kept.sorted()).write(to: url, options: .atomic)
        }.value
    }

    /// Updates when each item on Deleted on iPhone was first seen there, in the library's `.photobackup`.
    private func noteLeftPhone(_ server: BackupServer) async {
        let url = server.location.url.appending(path: ".photobackup/left-iphone.json")
        var known = leftPhoneAt
        if leftPhoneReadFrom != url {
            known = await Task.detached(priority: .userInitiated) { () -> [String: Date] in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return (try? decoder.decode([String: Date].self, from: Data(contentsOf: url))) ?? [:]
            }.value
            leftPhoneReadFrom = url
        }
        let now = Set(server.devices.flatMap { deletedOnPhone($0.id) }.map(\.id))
        var changed = false
        var fresh: [String: Int] = [:]
        for id in now where known[id] == nil {
            known[id] = .now
            changed = true
            fresh[String(id.prefix { $0 != "/" }), default: 0] += 1
        }
        // Newly seen deleted on an iPhone: ask what to do with the backups (unless that's automatic).
        for (deviceID, count) in fresh where !server.acceptPhoneChanges {
            if let device = server.devices.first(where: { $0.id == deviceID }) { MacNotifications.deletedOnPhone(count, on: device.name) }
        }
        // Back on its iPhone, or dealt with. Only for iPhones whose library list was read: without it,
        // nothing looks deleted, and the days so far mustn't be lost.
        let listed = Set(onPhone.keys)
        for id in known.keys where !now.contains(id) && listed.contains(String(id.prefix { $0 != "/" })) {
            known[id] = nil
            changed = true
        }
        leftPhoneAt = known
        guard changed else { return }
        let record = known
        await Task.detached {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoder.encode(record).write(to: url, options: .atomic)
        }.value
    }

    func items(in scope: Scope, deviceID: String? = nil, kind: Kind = .all) -> [MediaItem] {
        let source: [MediaItem] = switch scope {
        case .trash: trash.map(\.item)
        case .large: largeItems()
        case .deletedOnPhone(let deviceID): deletedOnPhone(deviceID)
        case .onThisDay: items.filter { Self.isOnThisDay($0.date) }
        case .items(let ids): items.filter { [wanted = Set(ids)] in wanted.contains($0.id) }
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

    /// Which media the library's views show: what's on the iPhones (all, or one), or everything on
    /// the backup drive. Imago is for managing what's on the iPhones, so that's the default.
    enum Source: Hashable {
        /// On any iPhone at its last backup.
        case phones
        /// On this iPhone (by device ID) at its last backup.
        case phone(String)
        /// Everything on the drive: also what's left the iPhones, and files from elsewhere.
        case drive

        static let key = "librarySource"
        static let folderKey = "folderSource"
        static let trashKey = "trashSource"

        init(raw: String) {
            if raw == "drive" { self = .drive } else if raw.hasPrefix("phone:") { self = .phone(String(raw.dropFirst(6))) } else { self = .phones }
        }

        var raw: String {
            switch self {
            case .phones: "phones"
            case .phone(let id): "phone:\(id)"
            case .drive: "drive"
            }
        }
    }

    /// Keeps the items `source` shows.
    /// Waiting files show with their iPhone's photos too (an edited copy: see `waitingFor`).
    func filter(_ items: [MediaItem], by source: Source) -> [MediaItem] {
        switch source {
        case .drive: items
        case .phones: items.filter { phoneAsset($0) != nil || waitingFor($0) != nil }
        case .phone(let id): items.filter { ($0.deviceID == id && phoneAsset($0) != nil) || waitingFor($0) == id }
        }
    }

    /// The iPhone a file beside its backups is waiting to go to (an edited copy saved next to its
    /// original: Not synced until sent, then on its way until the iPhone has it), by device ID. Nil
    /// for everything else.
    func waitingFor(_ item: MediaItem) -> String? {
        if let deviceID = item.deviceID {
            return item.assetID?.hasPrefix("mac-") == true && phoneAsset(item) == nil ? deviceID : nil
        }
        guard let top = item.folder?.split(separator: "/").first else { return nil }
        return phoneFolderOwners[String(top)]
    }

    /// Where an item is from: on an iPhone (at its last backup), or only on the drive.
    enum Origin: Hashable {
        case phone(String)
        case drive
    }

    func origin(of item: MediaItem) -> Origin {
        if let deviceID = item.deviceID, phoneAsset(item) != nil { return .phone(deviceID) }
        return .drive
    }

    /// The item as it is on its phone, if it was there at the last backup.
    func phoneAsset(_ item: MediaItem) -> PhoneAsset? {
        guard let deviceID = item.deviceID, let assetID = item.assetID else { return nil }
        return onPhone[deviceID]?[assetID]
    }

    /// Items backed up from an iPhone that weren't on it at its last backup: deleted there since. Only
    /// ones still in its own folder: ones moved into a folder or deleted here were dealt with already.
    /// Empty until the iPhone has sent its library list.
    func deletedOnPhone(_ deviceID: String) -> [MediaItem] {
        // Worked out for every iPhone in one pass, once per change: the sidebar asks on every redraw,
        // and going through every item for each iPhone each time took a sixth of a second.
        if deletedOnPhoneCache?.revision != revision {
            var found: [String: [MediaItem]] = [:]
            for item in items where item.folder == nil {
                // Not files from the Mac on their way to it (`BackupServer.send`): they were never on it.
                guard let id = item.deviceID, let phone = onPhone[id], let assetID = item.assetID,
                      phone[assetID] == nil, !assetID.hasPrefix("mac-"), !kept.contains(item.id) else { continue }
                found[id, default: []].append(item)
            }
            deletedOnPhoneCache = (revision, found)
        }
        return deletedOnPhoneCache?.byDevice[deviceID] ?? []
    }

    /// Taken on today's month and day, in an earlier year.
    nonisolated static func isOnThisDay(_ date: Date?, today: Date = .now) -> Bool {
        guard let date else { return false }
        let calendar = Calendar.current
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let now = calendar.dateComponents([.year, .month, .day], from: today)
        return day.month == now.month && day.day == now.day && (day.year ?? 0) < (now.year ?? 0)
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
        activity = Activity(title: "Deleting for good", done: 0, total: items.count)
        defer { activity = nil }
        await perform(server) {
            defer {
                let gone = Set(items.map(\.id))
                trash.removeAll { gone.contains($0.id) }
                selection.subtract(gone)
                changedHere()
            }
            for (deviceID, assets) in Dictionary(grouping: items.map(\.item).filter { $0.deviceID != nil }, by: { $0.deviceID! }) {
                guard let device = server.devices.first(where: { $0.id == deviceID }), let store = server.store(for: device) else { continue }
                for batch in assets.chunked(25) {
                    try await store.deletePermanently(batch.compactMap(\.assetID))
                    activity?.done += batch.count
                }
            }
            for item in items.map(\.item) where item.deviceID == nil {
                activity?.detail = item.name
                try FileManager.default.removeItem(at: item.url)
                activity?.done += 1
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

    /// Every item (Recently Deleted too) by how a move finds it, for finding many at once.
    private func itemsByRef() -> [ItemRef: MediaItem] {
        var found: [ItemRef: MediaItem] = [:]
        for item in items + trash.map(\.item) {
            let ref = Self.ref(item)
            if case .file(let url) = ref { found[.file(url.lexicallyStandardized)] = item } else { found[ref] = item }
        }
        return found
    }

    private static func lookup(_ ref: ItemRef, in found: [ItemRef: MediaItem]) -> MediaItem? {
        if case .file(let url) = ref { return found[.file(url.lexicallyStandardized)] }
        return found[ref]
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
        let found = itemsByRef()
        let wanted: [(item: MediaItem, from: Place, to: Place)] = moves.compactMap { ref, to in
            guard let item = Self.lookup(ref, in: found) else { return nil }
            let from = place(of: item)
            // Only phone assets have a phone folder to go back to.
            guard from != to, !(to == .phoneFolder && item.deviceID == nil) else { return nil }
            return (item, from, to)
        }
        // Each moved item as it was, and how to find it now.
        var moved: [(was: MediaItem, now: ItemRef)] = []
        // Where each one went, to show at once (see `showMoves`).
        var landed: [(was: MediaItem, from: Place, to: Place, url: URL)] = []
        if let to = wanted.first?.to {
            let title = switch to {
            case .trash: "Deleting"
            case .phoneFolder: "Moving back to the iPhone's folder"
            case .folder(let path): "Moving to “\((path as NSString).lastPathComponent)”"
            }
            activity = Activity(title: title, done: 0, total: wanted.count)
        }
        defer {
            activity = nil
            // Thumbnails follow their files, so moved items don't make them again from the drive.
            let now = moved.isEmpty ? [:] : itemsByRef()
            for (was, ref) in moved {
                guard let now = Self.lookup(ref, in: now) else { continue }
                Thumbnails.shared.carryOver(from: was.url, to: now.url, bytes: was.bytes)
            }
        }
        await perform(server) {
            defer { showMoves(landed, server: server) }
            let phoneMoves = wanted.filter { $0.item.deviceID != nil }
            for (key, group) in Dictionary(grouping: phoneMoves, by: { "\($0.item.deviceID!)|\(String(describing: $0.to))" }) {
                guard let deviceID = key.split(separator: "|").first.map(String.init),
                      let device = server.devices.first(where: { $0.id == deviceID }), let store = server.store(for: device),
                      let to = group.first?.to else { continue }
                if let target = directory(to) { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true) }
                // All in one go, reading the index once; the ring moves with each item as it's done.
                let result = await store.move(group.compactMap(\.item.assetID), to: directory(to), saving: false) { name in
                    Task { @MainActor [weak self] in
                        self?.activity?.detail = name
                        self?.activity?.done += 1
                    }
                }
                for move in group {
                    guard let assetID = move.item.assetID, result.moved.keys.contains(assetID) else { continue }
                    done.append((Self.ref(move.item), move.from))
                    moved.append((move.item, Self.ref(move.item)))
                    if let url = result.moved[assetID] ?? nil { landed.append((move.item, move.from, to, url)) }
                }
                await store.saveIndexIfChanged()
                if let error = result.error { throw error }
            }
            for move in wanted where move.item.deviceID == nil {
                guard let target = directory(move.to) else { continue }
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let destination = Self.unusedURL(target.appending(path: move.item.url.lastPathComponent))
                activity?.detail = move.item.name
                try FileManager.default.moveItem(at: move.item.url, to: destination)
                activity?.done += 1
                done.append((.file(destination.lexicallyStandardized), move.from))
                moved.append((move.item, .file(destination.lexicallyStandardized)))
                landed.append((move.item, move.from, move.to, destination.lexicallyStandardized))
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
            activity = Activity(title: "Checking against the backup", done: 0, total: ids.count)
            let files = await store.storedFiles(of: ids)
            var verified: Set<String> = []
            // One asset at a time, so the progress panel moves; reading a big video takes a while.
            for (assetID, assetFiles) in files {
                activity?.detail = assetFiles.first?.url.lastPathComponent
                // A big video takes a while to read: the ring follows its bytes.
                let size = assetFiles.reduce(UInt64(0)) { $0 + ((try? $1.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0) }
                activity?.bytes = size > 64 << 20 ? (0, size) : nil
                let matches = await Task.detached(priority: .userInitiated) { [weak self] in
                    var before: UInt64 = 0
                    return !assetFiles.isEmpty && assetFiles.allSatisfy { file in
                        let sum = try? FileHasher.sha256(of: file.url) { read in
                            let done = before + read
                            Task { @MainActor in if self?.activity?.bytes != nil { self?.activity?.bytes = (done, size) } }
                        }
                        before += (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
                        return sum == file.sha256
                    }
                }.value
                activity?.bytes = nil
                if matches { verified.insert(assetID) }
                activity?.done += 1
            }
            activity = nil
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

    /// Deletes items from their iPhone and from this backup: the iPhone is asked to delete them (each
    /// checked against its backup first; the iPhone keeps them in its own Recently Deleted), and the
    /// backed-up copies go to Imago's Recently Deleted here on the Mac, so Put Back returns them.
    /// Returns one step that undoes both.
    /// A backup that's already in Recently Deleted is checked there, and stays there.
    func deleteFromPhoneAndHere(_ items: [MediaItem], server: BackupServer) async -> FileHistory.Step? {
        let removal = await removeFromPhone(items, server: server)
        // Only what the iPhone was asked to delete: items that failed the check stay put.
        let asked = items.filter { pendingRemoval.contains($0.id) }
        let toTrash = asked.filter { trashed($0) == nil }
        let trashed = toTrash.isEmpty ? nil : await trash(toTrash, server: server)
        return FileHistory.combine(asked.count == 1 ? "Delete" : "Delete \(asked.count) Items", [removal, trashed])
    }

    /// Delete, from the library's own pages (Library, Places, On This Day, Large Files): what's still on
    /// an iPhone is deleted there too, as on the iPhone's page, and its backup goes to Recently Deleted
    /// here; what's only on the drive just goes to Recently Deleted. One step undoes it all.
    func delete(_ items: [MediaItem], server: BackupServer) async -> FileHistory.Step? {
        let onPhones = items.filter { phoneAsset($0) != nil }
        let driveOnly = items.filter { phoneAsset($0) == nil }
        let fromPhones = onPhones.isEmpty ? nil : await deleteFromPhoneAndHere(onPhones, server: server)
        let trashed = driveOnly.isEmpty ? nil : await trash(driveOnly, server: server)
        return FileHistory.combine(items.count == 1 ? "Delete" : "Delete \(items.count) Items", [fromPhones, trashed])
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
            renamed = true
            for device in server.devices {
                await server.store(for: device)?.folderMoved(from: old, to: new)
            }
        }
        guard renamed else { return nil }
        showRenamed(path, to: newPath, server: server)
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

    // MARK: Changes on the drive

    func beginWork() { working += 1 }

    func endWork() { working -= 1 }

    /// Watches the backup location for changes made outside Imago, while it's there.
    private func watch(_ server: BackupServer) {
        guard server.location.isAvailable else {
            watcher = nil
            return
        }
        let root = server.location.url.lexicallyStandardized
        guard watcher?.root != root else { return }
        watcher = DriveWatcher(root: root) { [weak self, weak server] folders, below in
            Task { @MainActor in
                guard let self, let server else { return }
                self.driveChanged(folders, below: below, server: server)
            }
        }
    }

    /// Folders changed on the drive: a moment later, once any work here is done, the items in just
    /// those folders are brought up to date (`reconcile`). What's hidden (`.photobackup`, sidecars)
    /// doesn't count.
    private func driveChanged(_ folders: [URL], below: Bool, server: BackupServer) {
        let root = server.location.url.lexicallyStandardized.pathComponents
        let visible = folders.map(\.lexicallyStandardized).filter { folder in
            let parts = folder.pathComponents
            return parts.count >= root.count && Array(parts.prefix(root.count)) == root
                && !parts.dropFirst(root.count).contains { $0.hasPrefix(".") }
        }
        guard !visible.isEmpty || below else { return }
        changedFolders.formUnion(visible)
        changedBelow = changedBelow || below
        guard reconciling == nil else { return }
        reconciling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            while let self, !Task.isCancelled, !self.changedFolders.isEmpty || self.changedBelow {
                // Nothing shown to bring up to date: the next read of the library shows the drive as it is.
                if self.state != .ready {
                    self.changedFolders = []
                    self.changedBelow = false
                    break
                }
                // After work here and any read under way: they show their own changes.
                if self.working > 0 || self.loading != nil {
                    try? await Task.sleep(for: .milliseconds(300))
                    continue
                }
                if self.changedBelow {
                    self.changedBelow = false
                    self.changedFolders = []
                    self.refreshQuietly(server)
                    continue
                }
                let folders = self.changedFolders
                self.changedFolders = []
                await self.reconcile(folders, server: server)
            }
            self?.reconciling = nil
        }
    }

    /// Brings the items in these folders up to date with what's on the drive: files added there show,
    /// files gone from there leave. Their own changes Imago has shown already, so for those nothing
    /// differs. A file another iPhone's index lost (moved in Finder) has the library read again, to
    /// show it with its iPhone's details.
    private func reconcile(_ folders: Set<URL>, server: BackupServer) async {
        let generation = loadGeneration
        let root = server.foldersURL.lexicallyStandardized
        let trashURL = server.trashURL.lexicallyStandardized
        let reserved = server.reservedFolderNames
        let phoneFolders = Set(server.devices.map(\.folder))
        // Worked out away from the main thread: tens of thousands of paths. Items' files are kept
        // standardized, so their paths are used as they are.
        let (all, trashed) = (items, trash)
        let (candidates, gone, shownPhone) = await Task.detached(priority: .userInitiated) { () -> ([URL], Set<String>, Set<String>) in
            var shownIn: [String: Set<String>] = [:]
            var knownFolders: Set<String> = []
            var shownPhone: Set<String> = []
            let rootPath = root.path
            for item in all + trashed.map(\.item) {
                let path = item.url.path
                if item.deviceID != nil { shownPhone.insert(path) }
                var folder = (path as NSString).deletingLastPathComponent
                shownIn[folder, default: []].insert(path)
                while folder.count > rootPath.count, knownFolders.insert(folder).inserted {
                    folder = (folder as NSString).deletingLastPathComponent
                }
            }
            /// Where the library looks: the user's folders, the iPhones' own folders and Recently Deleted.
            func isLookedAt(_ folder: URL) -> Bool {
                let parts = folder.pathComponents
                let base = root.pathComponents
                guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return false }
                let top = parts[base.count]
                return !reserved.contains(top) || phoneFolders.contains(top) || Self.isInside(folder, trashURL) || folder == trashURL
            }
            DriveScan.shared.forget(Array(folders))
            var candidates: [URL] = []
            var gone: Set<String> = []
            var goneBelow: [String] = []
            for folder in folders {
                guard folder == root || isLookedAt(folder) else { continue }
                guard let contents = DriveScan.shared.contents(of: folder) else {
                    goneBelow.append(folder.path + "/")
                    continue
                }
                if folder != root {
                    let disk = Set(contents.media.map(\.path))
                    let here = shownIn[folder.path] ?? []
                    candidates += contents.media.filter { !here.contains($0.path) }
                    gone.formUnion(here.subtracting(disk))
                }
                // Folders new to the library (copied in, renamed in Finder): everything in them.
                let inside = Set(contents.folders.map(\.path))
                for sub in contents.folders where !knownFolders.contains(sub.path) && isLookedAt(sub) {
                    candidates += DriveScan.shared.mediaFiles(in: sub)
                }
                // Folders that left it: everything that was in them.
                for known in knownFolders where (known as NSString).deletingLastPathComponent == folder.path && !inside.contains(known) {
                    goneBelow.append(known + "/")
                }
            }
            if !goneBelow.isEmpty {
                for paths in shownIn.values {
                    for path in paths where goneBelow.contains(where: { path.hasPrefix($0) }) { gone.insert(path) }
                }
            }
            DriveScan.shared.save()
            return (candidates, gone, shownPhone)
        }.value

        // Files an iPhone's index holds are that iPhone's (a Live Photo's video, a received file):
        // the index says what they are.
        var unknown = Array(Set(candidates))
        let stores = server.devices.compactMap { server.store(for: $0) }
        for store in stores where !unknown.isEmpty {
            let held = await store.held(unknown)
            unknown.removeAll { held.contains($0) }
        }
        var claimed: Set<URL> = []
        for store in stores where !unknown.isEmpty {
            claimed.formUnion(await store.relink(unknown.filter { !claimed.contains($0) }))
        }
        if !claimed.isEmpty {
            refreshQuietly(server)
            return
        }
        // Gone from where an iPhone's index has them: the next read of the library sorts those out.
        let leaving = gone.subtracting(shownPhone)
        guard !unknown.isEmpty || !leaving.isEmpty else { return }
        let manifest = await Task.detached(priority: .userInitiated) { TrashManifest.read(in: trashURL) }.value
        let added = await Task.detached(priority: .userInitiated) {
            unknown.map { Self.fileItem($0, in: root, reserved: reserved) }
        }.value
        // Changed here meanwhile: look at these folders again.
        guard generation == loadGeneration else {
            changedFolders.formUnion(folders)
            return
        }
        items.removeAll { $0.deviceID == nil && leaving.contains($0.url.path) }
        trash.removeAll { $0.item.deviceID == nil && leaving.contains($0.item.url.path) }
        for item in added {
            if Self.isInside(item.url, trashURL) {
                var item = item
                item.folder = nil
                let record = manifest.entries[TrashManifest.key(forFile: item.url)]
                trash.append(TrashedItem(item: item, deletedAt: record?.deletedAt ?? .now, originalPlace: record?.from ?? .folder("")))
            } else {
                items.append(item)
            }
        }
        items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        trash.sort { $0.deletedAt > $1.deletedAt }
        selection.formIntersection(items.map(\.id) + trash.map(\.id))
        await reloadFolders(server)
        changedHere()
        findFolderCopies(server)
        fillDurations()
        sendNotSynced(server)
    }

    // MARK: Helpers

    /// Does file work that updates what's on screen itself, as Finder does: the library isn't read
    /// again after it. Only when the work fails partway is it read again (quietly), to show what
    /// actually happened.
    private func perform(_ server: BackupServer, _ work: () async throws -> Void) async {
        working += 1
        defer { working -= 1 }
        do {
            try await work()
        } catch {
            self.error = error.localizedDescription
            refreshQuietly(server)
        }
        Task { await server.refreshSummaries() }
    }

    /// What's on screen was just changed here, without reading the library (a move, a copy, an undo):
    /// a read under way began before it, so it's dropped and runs once more.
    private func changedHere() {
        loadGeneration += 1
        if loading != nil { loadAgain = true }
        revision += 1
    }

    /// Files beside an iPhone's backups that it doesn't have (an edited copy saved next to its
    /// original): "Not synced" until they go to it.
    func notSynced(on device: PairedDevice) -> [MediaItem] {
        let folder = device.folder
        return items.filter { item in
            item.deviceID == nil && (item.folder == folder || item.folder?.hasPrefix(folder + "/") == true)
        }
    }

    /// Files from the Mac on their way to an iPhone (adopted, the iPhone hasn't answered yet).
    func sending(to device: PairedDevice) -> [MediaItem] {
        items.filter { $0.deviceID == device.id && $0.assetID?.hasPrefix("mac-") == true }
    }

    /// Sends Not synced files to each iPhone with Imago open on it: an edit made here goes to the
    /// iPhone straight away. Ones not connected get theirs when they connect.
    func sendNotSynced(_ server: BackupServer) {
        for device in server.devices where server.liveDevices.contains(device.id) {
            let waiting = notSynced(on: device).filter { !sendingPaths.contains($0.url.path) && !server.declinedAdds.contains($0.url.path) }
            guard !waiting.isEmpty else { continue }
            // Kept until a reload shows them as the iPhone's: until then they still look Not synced.
            sendingPaths.formUnion(waiting.map(\.url.path))
            Task { await server.send(waiting, to: device) }
        }
    }

    /// Videos whose length isn't known (ones no iPhone's index describes: edited copies, copies in
    /// folders, files from Finder) get it, read in the background (see `VideoDurations`), so their
    /// tiles show it like the rest.
    func fillDurations() {
        let unknown = (items + trash.map(\.item)).filter { $0.isVideo && $0.duration == 0 }.map(\.url)
        guard !unknown.isEmpty else { return }
        durationFill?.cancel()
        durationFill = Task { [weak self] in
            let found = await VideoDurations.lengths(of: unknown)
            guard !Task.isCancelled, let self, !found.isEmpty else { return }
            var changed = false
            for i in items.indices where items[i].isVideo && items[i].duration == 0 {
                if let seconds = found[items[i].url] { items[i].duration = seconds; changed = true }
            }
            for i in trash.indices where trash[i].item.isVideo && trash[i].item.duration == 0 {
                if let seconds = found[trash[i].item.url] { trash[i].item.duration = seconds; changed = true }
            }
            if changed { revision += 1 }
        }
    }

    /// Works out, in the background, which iPhone items are also in the folders (`inFolders`).
    /// Files are read only when an iPhone item has the same size, and each one only once: what it
    /// holds is kept in `.photobackup/folder-hashes.json` until the file changes.
    func findFolderCopies(_ server: BackupServer) {
        folderCopySearch?.cancel()
        let phone = items.filter { $0.deviceID != nil }
        let files = items.filter { $0.deviceID == nil && $0.folder != nil }
        let cacheURL = server.location.url.appending(path: ".photobackup/folder-hashes.json")
        folderCopySearch = Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                FolderCopies.find(phone: phone, files: files, cacheURL: cacheURL)
            }.value
            guard !Task.isCancelled, let self, found != self.inFolders else { return }
            self.inFolders = found
            self.revision += 1
        }
    }

    /// Reads the whole library again in the background, to catch what the quick updates can't know
    /// (a new folder's count, a file's numbered name). Several in a row become one.
    func refreshQuietly(_ server: BackupServer) {
        // What's on screen is newer than any read under way.
        loadGeneration += 1
        quietRefresh?.cancel()
        quietRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            isRefreshing = true
            await load(from: server, force: true)
            await server.refreshSummaries()
            // A newer one took over: it says when it's done.
            if !Task.isCancelled { isRefreshing = false }
        }
    }

    /// Shows moved items where they went, straight away: in their new folder, in Recently Deleted, or
    /// back out of it. The library isn't read again after.
    private func showMoves(_ landed: [(was: MediaItem, from: Place, to: Place, url: URL)], server: BackupServer) {
        guard !landed.isEmpty else { return }
        let foldersURL = server.foldersURL
        let reserved = server.reservedFolderNames
        let phoneFolders = Set(server.devices.map(\.folder))
        let oldIDs = Set(landed.map(\.was.id))
        items.removeAll { oldIDs.contains($0.id) }
        trash.removeAll { oldIDs.contains($0.id) }
        var added: [MediaItem] = []
        for move in landed {
            var item = move.was
            item.url = move.url
            // A file from elsewhere is known by its path.
            if item.deviceID == nil { item.id = move.url.path }
            if move.to == .trash {
                item.folder = nil
                trash.insert(TrashedItem(item: item, deletedAt: .now, originalPlace: move.from), at: 0)
            } else {
                // A file beside an iPhone's backups (Not synced) is known by where it is there too.
                item.folder = Self.folderPath(of: move.url, in: foldersURL, reserved: reserved)
                    ?? (item.deviceID == nil ? Self.phoneFolderPath(of: move.url, in: foldersURL, phoneFolders: phoneFolders) : nil)
                added.append(item)
            }
        }
        if !added.isEmpty {
            items.append(contentsOf: added)
            items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
        selection.subtract(oldIDs.subtracting(added.map(\.id)))
        folders = folderTree(adding: added.compactMap(\.folder))
        changedHere()
        findFolderCopies(server)
    }

    /// Shows a renamed folder's items in it under its new name, and the folder in the sidebar.
    private func showRenamed(_ path: String, to newPath: String, server: BackupServer) {
        let oldBase = server.foldersURL.appending(path: path, directoryHint: .isDirectory).lexicallyStandardized.path
        let newBase = server.foldersURL.appending(path: newPath, directoryHint: .isDirectory).lexicallyStandardized.path
        func renamed(_ folder: String) -> String? {
            folder == path ? newPath : folder.hasPrefix(path + "/") ? newPath + folder.dropFirst(path.count) : nil
        }
        var paths = Self.paths(of: folders).map { renamed($0) ?? $0 }
        paths.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        var oldIDs: [String: String] = [:]
        for i in items.indices {
            guard let folder = items[i].folder, let moved = renamed(folder) else { continue }
            let was = items[i]
            items[i].folder = moved
            items[i].url = URL(filePath: newBase + was.url.lexicallyStandardized.path.dropFirst(oldBase.count))
            if was.deviceID == nil {
                items[i].id = items[i].url.path
                oldIDs[was.id] = items[i].id
            }
            Thumbnails.shared.carryOver(from: was.url, to: items[i].url, bytes: was.bytes)
        }
        selection = Set(selection.map { oldIDs[$0] ?? $0 })
        folders = Self.tree(paths, items: items)
        changedHere()
        findFolderCopies(server)
    }

    /// Shows files just copied into folders, straight away.
    func showCopies(_ urls: [URL], server: BackupServer) {
        guard !urls.isEmpty else { return }
        let foldersURL = server.foldersURL
        let reserved = server.reservedFolderNames
        let added = urls.map { Self.fileItem($0.lexicallyStandardized, in: foldersURL, reserved: reserved) }
        items.append(contentsOf: added)
        items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        folders = folderTree(adding: added.compactMap { Self.folderPath(of: $0.url, in: foldersURL, reserved: reserved) })
        changedHere()
        findFolderCopies(server)
        fillDurations()
        sendNotSynced(server)
    }

    /// Takes files that were just removed (an undone copy) off the page.
    func hideRemoved(_ urls: [URL], server: BackupServer) {
        let gone = Set(urls.map { $0.lexicallyStandardized.path })
        items.removeAll { $0.deviceID == nil && gone.contains($0.url.lexicallyStandardized.path) }
        selection.subtract(gone)
        folders = folderTree()
        changedHere()
        findFolderCopies(server)
    }

    /// Whether the folder at this path ("Tennis/Serve") is there.
    func hasFolder(_ path: String) -> Bool {
        Self.paths(of: folders).contains(path)
    }

    /// Every folder's path in a tree, parents first.
    private static func paths(of folders: [Folder]) -> [String] {
        folders.flatMap { [$0.path] + paths(of: $0.children ?? []) }
    }

    /// The folders again with their counts worked out anew, and `adding` (and the folders they're
    /// in) among them: a move or copy into a folder that was just made.
    private func folderTree(adding new: [String] = []) -> [Folder] {
        var paths = Self.paths(of: folders)
        var known = Set(paths)
        for path in new where !path.isEmpty {
            var parts: [String] = []
            for part in path.split(separator: "/") {
                parts.append(String(part))
                let path = parts.joined(separator: "/")
                if known.insert(path).inserted { paths.append(path) }
            }
        }
        paths.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return Self.tree(paths, items: items)
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

    /// A file added to an iPhone's own folder (an edited copy beside its original): where it is, as a
    /// path from the top of the backup location ("007/2026/10"), so moving it and undoing find their way.
    nonisolated private static func phoneFolderPath(of url: URL, in root: URL, phoneFolders: Set<String>) -> String? {
        let base = root.lexicallyStandardized.pathComponents
        let parts = url.lexicallyStandardized.pathComponents
        guard parts.count > base.count + 1, Array(parts.prefix(base.count)) == base, phoneFolders.contains(parts[base.count]) else { return nil }
        return parts[base.count..<(parts.count - 1)].joined(separator: "/")
    }

    /// Where an edited copy of `item` goes: beside it, in its folder or its iPhone's folder.
    func editedCopyFolder(for item: MediaItem, server: BackupServer) -> String {
        item.folder ?? Self.phoneFolderPath(of: item.url, in: server.foldersURL, phoneFolders: Set(server.devices.map(\.folder)))
            ?? server.editedFolder
    }

    /// Every one of the user's folders, as paths from the top of the backup location, parents before
    /// children. The phones' folders and Recently Deleted (`reserved`) aren't looked into.
    /// An iPhone's items from its catalog, and every file its index knows.
    nonisolated private static func items(from entries: [BackupStore.CatalogEntry], deviceID: String,
                                          foldersURL: URL, trashURL: URL, reserved: Set<String>) -> CatalogItems {
        var files: Set<URL> = []
        var items: [MediaItem] = []
        var trashed: [MediaItem] = []
        items.reserveCapacity(entries.count)
        for entry in entries {
            files.formUnion(entry.files.map(\.url))
            guard let display = entry.display else { continue }
            var item = MediaItem(
                id: "\(deviceID)/\(entry.assetID)", url: display.url,
                name: entry.metadata.originalFilename, date: entry.metadata.creationDate,
                isVideo: entry.metadata.mediaType == "video", duration: entry.metadata.duration,
                bytes: entry.files.reduce(0) { $0 + $1.size },
                folder: folderPath(of: display.url, in: foldersURL, reserved: reserved),
                deviceID: deviceID, assetID: entry.assetID,
                latitude: entry.metadata.location?.latitude, longitude: entry.metadata.location?.longitude,
                original: .init(size: display.size, sha256: display.sha256)
            )
            if isInside(display.url, trashURL) {
                item.folder = nil
                trashed.append(item)
            } else {
                items.append(item)
            }
        }
        return CatalogItems(items: items, trashed: trashed, files: files)
    }

    nonisolated private static func folderPaths(in root: URL, reserved: Set<String>) -> [String] {
        let scan = DriveScan.shared
        var paths: [String] = []
        for top in scan.subfolders(of: root) where !reserved.contains(top) {
            paths.append(top)
            paths += scan.folders(in: root.appending(path: top, directoryHint: .isDirectory)).map { top + "/" + $0 }
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
        DriveScan.shared.mediaFiles(in: directory)
    }

    nonisolated private static func fileItem(_ url: URL, in foldersURL: URL, reserved: Set<String>, folder: String?? = .none) -> MediaItem {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .creationDateKey])
        return MediaItem(
            id: url.path, url: url, name: url.lastPathComponent, date: values?.creationDate,
            isVideo: values?.contentType?.conforms(to: .movie) ?? false, duration: 0,
            bytes: UInt64(values?.fileSize ?? 0),
            folder: folder ?? folderPath(of: url, in: foldersURL, reserved: reserved) ?? phoneFolderPath(of: url, in: foldersURL, phoneFolders: reserved)
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

    /// The manifest as last read or written, with the file's date then: every library read asks for
    /// it, and while the file is unchanged there's no need to read it off the drive again.
    private static let cache = Mutex<(url: URL, modified: Date, manifest: TrashManifest)?>(nil)

    static func read(in directory: URL) -> TrashManifest {
        let url = url(in: directory)
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let modified, let cached = cache.withLock({ $0 }), cached.url == url, cached.modified == modified {
            return cached.manifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = (try? decoder.decode(TrashManifest.self, from: Data(contentsOf: url))) ?? TrashManifest()
        if let modified { cache.withLock { $0 = (url, modified, manifest) } }
        return manifest
    }

    func write(in directory: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = Self.url(in: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: url, options: .atomic)
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        Self.cache.withLock { $0 = modified.map { (url, $0, self) } }
    }
}

extension Array {
    /// The elements in runs of `size`.
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}

/// Finds the folders an iPhone item is in: where its backup was moved, and where an identical file
/// was copied (Copy | Move, Finder, AirDrop).
enum FolderCopies {
    struct Fingerprint: Hashable, Sendable {
        var size: UInt64
        var sha256: String
    }

    /// One place an item is in: the folder ("Videos/tennis") and the file there.
    struct Copy: Hashable, Sendable {
        var folder: String
        var url: URL
    }

    /// A folder file's content, as last read.
    private struct Known: Codable {
        var size: UInt64
        var modified: Date
        var sha256: String
    }

    static func find(phone: [MediaItem], files: [MediaItem], cacheURL: URL) -> [String: [Copy]] {
        var found: [String: [Copy]] = [:]
        var bySHA: [String: [String]] = [:]
        var sizes: Set<UInt64> = []
        for item in phone {
            if let folder = item.folder { found[item.id, default: []].append(Copy(folder: folder, url: item.url)) }
            if let original = item.original {
                bySHA[original.sha256, default: []].append(item.id)
                sizes.insert(original.size)
            }
        }
        var cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode([String: Known].self, from: $0) } ?? [:]
        var changed = false
        for file in files {
            guard let folder = file.folder, sizes.contains(file.bytes) else { continue }
            if Task.isCancelled { break }
            let modified = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let sha: String
            if let known = cache[file.url.path], known.size == file.bytes, known.modified == modified {
                sha = known.sha256
            } else {
                guard let read = try? FileHasher.sha256(of: file.url) else { continue }
                sha = read
                cache[file.url.path] = Known(size: file.bytes, modified: modified, sha256: read)
                changed = true
            }
            for id in bySHA[sha] ?? [] {
                found[id, default: []].append(Copy(folder: folder, url: file.url))
            }
        }
        // Forget files that are gone.
        let present = Set(files.map(\.url.path))
        if cache.keys.contains(where: { !present.contains($0) }) {
            cache = cache.filter { present.contains($0.key) }
            changed = true
        }
        if changed, let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
        return found.mapValues { $0.sorted { ($0.folder, $0.url.lastPathComponent) < ($1.folder, $1.url.lastPathComponent) } }
    }
}

extension BackupServer {
    /// The folder for edited copies of iPhone backups: "Edited", unless an iPhone has that name.
    var editedFolder: String {
        var name = "Edited", n = 2
        while reservedFolderNames.contains(name) { name = "Edited \(n)"; n += 1 }
        return name
    }
}
