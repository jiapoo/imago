import AppKit
import CoreLocation
import ImagoKit
import SwiftUI

/// The library, one folder, Recently Deleted or Large Files: a grid. Click to select (⌘ and ⇧ to
/// add), double-click or Space to open in the viewer, ⌘O for the default app, pinch to resize,
/// Delete to move to Recently Deleted (⌘Z puts it back). Drag items onto a folder in the sidebar or
/// the Files panel.
struct BrowserView: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    @Environment(MediaViewerHost.self) private var viewer
    @Environment(FileHistory.self) private var history
    let scope: MediaLibrary.Scope
    /// Inside another page (a place's panel on the map): no title or toolbar of its own.
    var embedded = false
    /// Goes to a folder's page: a subfolder's card, the path bar, ⌘↑.
    var openFolder: (String) -> Void = { _ in }

    @State private var kind: MediaLibrary.Kind = .all
    /// Large Files: only items still on an iPhone.
    /// Library, On This Day and Large Files: on the iPhones (all, or one), or everything on the drive.
    @AppStorage(MediaLibrary.Source.key) private var sourceRaw = MediaLibrary.Source.phones.raw
    /// Folders filter on their own: what's in a folder is on the drive, so they show all of it unless asked.
    @AppStorage(MediaLibrary.Source.folderKey) private var folderSourceRaw = MediaLibrary.Source.drive.raw
    /// Recently Deleted too, on its own.
    @AppStorage(MediaLibrary.Source.trashKey) private var trashSourceRaw = MediaLibrary.Source.drive.raw
    @AppStorage("browserTileSize") private var tileSize = 150.0
    /// A folder shows only what's directly in it, as in Finder, unless this is on.
    @AppStorage("includeSubfolders") private var includeSubfolders = false
    /// The subfolders' cards at the top of a folder: folded away unless opened.
    @AppStorage("showSubfolderCards") private var showSubfolderCards = false
    @State private var anchor: MediaItem.ID?
    /// Where the anchor's thumbnail is, for the viewer to grow out of.
    @State private var anchorFrame: CGRect?
    /// Where each tile is, for the selection box.
    @State private var tileFrames = TileFrames()
    /// Recently Deleted: items to delete for good, while the confirmation is up.
    @State private var deletingNow: [TrashedItem]?
    /// Items to ask their iPhone to remove, while the confirmation is up.
    @State private var removing: [MediaItem]?
    /// The item the grid scrolls to next (the banner's Show).
    @State private var scrollTarget: MediaItem.ID?
    @State private var naming: FolderNaming?
    /// Deleted on iPhone: the Delete All confirmation is up.
    @State private var confirmingDeleteAll = false
    @FocusState private var focused: Bool

    @State private var cache = GridCache()

    /// What the grid shows, worked out once per change to the library or the filters, not on every
    /// redraw: selecting redraws the page, and the library can have tens of thousands of items.
    private var shown: GridCache {
        let key = GridCache.Key(revision: library.revision, scope: scope, kind: kind, source: showsSource ? source.raw : "",
                                subfolders: includeSubfolders)
        if cache.key != key {
            var items = library.items(in: scope, kind: kind)
            if case .folder(let path) = scope, !includeSubfolders { items.removeAll { $0.folder != path } }
            cache.items = showsSource ? library.filter(items, by: source) : items
            cache.days = isFlat ? [] : Day.group(cache.items)
            cache.ids = Set(cache.items.map(\.id))
            cache.key = key
        }
        return cache
    }
    private var items: [MediaItem] { shown.items }
    private var selected: [MediaItem] {
        let selection = library.selection
        guard !selection.isEmpty else { return [] }
        return items.filter { selection.contains($0.id) }
    }
    private var isTrash: Bool { scope == .trash }
    /// Pages with the Show menu (on the iPhones, or everything on the drive).
    private var showsSource: Bool {
        switch scope {
        case .all, .large, .onThisDay, .folder, .trash: true
        default: false
        }
    }
    private var sourceName: String {
        if case .phone(let id) = source { server.devices.first { $0.id == id }?.name ?? "that iPhone" } else { "your iPhones" }
    }
    private var isFolder: Bool { if case .folder = scope { true } else { false } }
    private var source: MediaLibrary.Source {
        MediaLibrary.Source(raw: isFolder ? folderSourceRaw : isTrash ? trashSourceRaw : sourceRaw)
    }
    /// Large Files and Recently Deleted keep their own order (by size; by when deleted), so they aren't
    /// split into days: out of date order, one day would turn up in several places.
    private var isFlat: Bool { scope == .large || scope == .trash }

    var body: some View {
        let items = items
        grid(items)
            .overlay { emptyState(isEmpty: items.isEmpty) }
            .overlay(alignment: .bottom) { selectionBar }
            .animation(.snappy(duration: 0.25), value: selected.isEmpty)
            .modifier(keyHandling(items))
            .onChange(of: viewer.isOpen) { _, open in if !open { focused = true } }
            .modifier(dialogs)
            .confirmationDialog(deleteAllTitle, isPresented: $confirmingDeleteAll) {
                Button("Move to Recently Deleted", role: .destructive) { trash(library.items(in: scope)) }
            } message: {
                Text("They were deleted on the iPhone already; this moves the backed-up copies to Recently Deleted on this Mac. Put Back returns them, and ⌘Z undoes it.")
            }
            .modifier(PageChrome(embedded: embedded, title: title, subtitle: subtitle(items)) { toolbar })
            .task(id: server.catalogRevision) { await library.load(from: server) }
            .onChange(of: scope) { library.selection = []; anchor = nil }
            // Photos and videos open from the backup drive: keep it spinning while the grid is up.
            .onAppear { server.keepDriveAwake(true) }
            .onDisappear { server.keepDriveAwake(false) }
    }

    private func grid(_ items: [MediaItem]) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 0) {
            if case .folder(let path) = scope {
                folderHeader(path, count: items.count).padding(.horizontal, 16)
                phoneBanner.padding(.horizontal, 16)
            }
            if isTrash, !items.isEmpty { trashBanner.padding(.horizontal, 16) }
            if case .deletedOnPhone = scope, !items.isEmpty { deletedOnPhoneBanner.padding(.horizontal, 16) }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.5), spacing: 4)],
                spacing: 4, pinnedViews: isFlat ? [] : [.sectionHeaders]
            ) {
                if isFlat {
                    // In their own order (biggest first; most recently deleted first), not by day.
                    ForEach(items) { item in tile(item, in: items) }
                } else {
                    ForEach(shown.days) { day in
                        Section {
                            ForEach(day.items) { item in tile(item, in: items) }
                        } header: {
                            DayHeader(day: day) { library.selection.formUnion(day.items.map(\.id)) }
                                .headerFrame("\(day.id.timeIntervalSinceReferenceDate)", in: tileFrames)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, isFlat ? 12 : 0)
            .padding(.bottom, 96)
          }
          .modifier(FillsViewport())
          .modifier(SelectionBox(frames: tileFrames, ids: { shown.ids },
                                 selection: Binding(get: { library.selection }, set: { library.selection = $0 })))
        }
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
        // A folder takes photos and videos dropped on it: from Finder (copied in) or another grid.
        .dropDestination(for: URL.self) { urls, _ in
            guard case .folder(let path) = scope else { return false }
            return library.drop(urls, onto: .folder(path), server: server, history: history)
        }
        .modifier(PinchToResize(size: $tileSize))
        .onChange(of: scrollTarget) { _, target in
            guard let target else { return }
            // After the grid has redrawn for a changed filter.
            DispatchQueue.main.async { withAnimation { proxy.scrollTo(target, anchor: .center) } }
            scrollTarget = nil
        }
        }
    }

    /// Selects these items and scrolls to the first, showing all kinds and subfolders if the filters hid it.
    private func show(_ targets: [MediaItem]) {
        guard let first = targets.first else { return }
        if !shown.ids.contains(first.id) { kind = .all; includeSubfolders = true }
        library.selection = Set(targets.map(\.id))
        anchor = first.id
        scrollTarget = first.id
    }

    private func tile(_ item: MediaItem, in items: [MediaItem]) -> some View {
        MediaTile(
            item: item,
            selected: library.selection.contains(item.id),
            pendingRemoval: library.pendingRemoval.contains(item.id)
                ? item.deviceID.map { SourceBadge.Style(.phone($0), server: server, waiting: true) } : nil,
            badge: badge(for: item),
            source: source(of: item),
            cameFrom: cameFrom(item),
            folders: otherFolders(holding: item)
        )
        .onTapGesture { click(item, in: items) }
        .contextMenu { menu(for: item) }
        .onDrag { dragProvider(for: item) }
        .reportsViewerSourceFrame(item.id == anchor, to: $anchorFrame)
        .tileFrame(item.id, in: tileFrames)
    }

    /// Bottom right: which iPhone (or the drive) its item is on now. Not in a Folder, Recently Deleted
    /// or Deleted on iPhone, where everything is on the drive.
    private func source(of item: MediaItem) -> SourceBadge.Style? {
        switch scope {
        case .deletedOnPhone:
            // Waiting to be put back on its iPhone: its dot, with a clock.
            if library.restoring.contains(item.id), let deviceID = item.deviceID {
                var style = SourceBadge.Style(.phone(deviceID), server: server, waiting: true)
                style.help = "Waiting to be put back on \(server.devices.first { $0.id == deviceID }?.name ?? "the iPhone")"
                return style
            }
            return nil
        case .trash: return nil
        case .folder: return nil // Everything in a Folder is on the drive.
        default: return SourceBadge.Style(library.origin(of: item), server: server)
        }
    }

    /// Adds files that didn't come from an iPhone to one's Photos library.
    private func sendToPhone(_ items: [MediaItem], _ device: PairedDevice) {
        let files = items.filter { $0.deviceID == nil }
        Task { await server.send(files, to: device) }
    }

    /// Top right: the folders an iPhone item is also in. In a folder, not that one (or one inside it).
    private func otherFolders(holding item: MediaItem) -> [FolderCopies.Copy] {
        let all = library.inFolders[item.id] ?? []
        guard case .folder(let path) = scope else { return all }
        return all.filter { $0.folder != path && !$0.folder.hasPrefix(path + "/") }
    }

    /// Bottom left, in a Folder and Recently Deleted: which iPhone it came from, wherever it is now.
    private func cameFrom(_ item: MediaItem) -> SourceBadge.Style? {
        switch scope {
        case .folder, .trash: SourceBadge.Style(item.deviceID.map { .phone($0) } ?? .drive, server: server, cameFrom: true)
        default: nil
        }
    }

    /// Recently Deleted: days left. Large Files: the size.
    private func badge(for item: MediaItem) -> String? {
        switch scope {
        case .trash:
            guard let days = library.trashed(item)?.daysLeft(keeping: server.trashDays) else { return nil }
            return days == 1 ? "1 day" : "\(days) days"
        case .large:
            return item.bytes.bytes
        case .deletedOnPhone:
            guard let days = library.daysUntilMoved(item, keeping: server.trashDays) else { return nil }
            return days == 1 ? "1 day" : "\(days) days"
        case .folder(let path):
            // With subfolders shown: which one each item is in.
            guard let folder = item.folder, folder != path else { return nil }
            return FolderMark.name(String(folder.dropFirst(path.count + 1)))
        default:
            return nil
        }
    }

    /// Drags the item, or the whole selection when it's part of it.
    private func dragProvider(for item: MediaItem) -> NSItemProvider {
        let urls = library.selection.contains(item.id) ? selected.map(\.url) : [item.url]
        DragSession.urls = urls
        return NSItemProvider(object: item.url as NSURL)
    }

    @ViewBuilder
    private var selectionBar: some View {
        if !selected.isEmpty {
            let selected = selected
            if isTrash {
                TrashSelectionBar(
                    items: selected,
                    sources: SourceBadge.summary(selected.map { $0.deviceID.map { .phone($0) } ?? .drive },
                                                 devices: server.devices, cameFrom: true),
                    putBack: { putBack(selected) },
                    deleteNow: { deletingNow = selected.compactMap(library.trashed) },
                    clear: { library.selection = [] }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                SelectionBar(
                    items: selected,
                    // A Folder's items are all on the drive: say which iPhones they came from.
                    sources: { if case .folder = scope {
                        SourceBadge.summary(selected.map { $0.deviceID.map { .phone($0) } ?? .drive }, devices: server.devices, cameFrom: true)
                    } else {
                        SourceBadge.summary(selected.map(library.origin), devices: server.devices)
                    } }(),
                    removable: library.removable(selected).count,
                    folders: otherFolders,
                    copies: selected.flatMap(otherFolders(holding:)).map(\.url),
                    sendable: selected.contains { $0.deviceID == nil } ? server.devices : [],
                    send: { device in sendToPhone(selected, device) },
                    canPutBack: selected.contains { $0.folder != nil && $0.deviceID != nil },
                    move: { folder in moveSelected(selected, to: folder) },
                    newFolder: { naming = .newFolder(moving: selected) },
                    removeFromPhone: { removing = selected },
                    deleteHelp: deletesOnPhone
                        ? "Delete (⌫): from the iPhone too, and the backup goes to Recently Deleted. ⌘Z undoes it."
                        : "Move to Recently Deleted (⌫). ⌘Z puts it back.",
                    trash: { trash(selected) },
                    clear: { library.selection = [] }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// In a Folder: how many of its items are still on an iPhone, with a button to remove them there.
    @ViewBuilder
    private var phoneBanner: some View {
        let inFolder = library.items(in: scope)
        let removable = library.removable(inFolder)
        let pending = inFolder.count { library.pendingRemoval.contains($0.id) }
        let phones = Set(removable.compactMap(\.deviceID)).count > 1 ? "iPhones" : "iPhone"
        if !removable.isEmpty {
            HStack(spacing: 14) {
                Image(systemName: "iphone")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(removable.count == 1 ? "1 item here is also still on your \(phones)" : "\(removable.count.formatted()) items here are also still on your \(phones)")
                        .font(.headline)
                    Text(removable.count == 1
                         ? "Removing it from the \(phones) frees \(removable.reduce(0) { $0 + $1.bytes }.bytes) there. The backup on this drive stays."
                         : "Removing them from the \(phones) frees \(removable.reduce(0) { $0 + $1.bytes }.bytes) there. The backups on this drive stay.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(removable.count == 1 ? "Show It" : "Show Them") { show(removable) }
                    .controlSize(.large)
                    .help("Select \(removable.count == 1 ? "it" : "them") in the grid")
                Button("Remove from \(phones)…") { removing = removable }
                    .controlSize(.large)
            }
            .padding(14)
            .background(.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 14)
        } else if pending > 0 {
            Label(pending == 1 ? "1 item here will be removed from your iPhone once you confirm it there."
                               : "\(pending.formatted()) items here will be removed from your iPhone once you confirm it there.",
                  systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
        }
    }

    /// Recently Deleted: how long items stay.
    private var trashBanner: some View {
        Label(server.trashDays > 0
              ? "Items are deleted for good \(server.trashDays) days after they're deleted. Put Back returns them where they were."
              : "Items stay until you empty Recently Deleted. Put Back returns them where they were.",
              systemImage: "trash")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
    }

    /// Deleted on iPhone: what these are, and what to do with them.
    private var deletedOnPhoneBanner: some View {
        Label(server.trashDays > 0
              ? "Backed up on this Mac, but deleted on the iPhone since. Delete them from this Mac too, keep the backups on this Mac, or put them back on the iPhone (right-click, or Decide for All). Undecided, each moves to Recently Deleted \(server.trashDays) days after it left the iPhone (the days on each)."
              : "Backed up on this Mac, but deleted on the iPhone since. Delete them from this Mac too, keep the backups on this Mac, or put them back on the iPhone (right-click, or Decide for All). They stay until you decide.",
              systemImage: "iphone.slash")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 14)
    }

    private var otherFolders: [String] {
        flatten(library.folders).map(\.path).filter { MediaLibrary.Scope.folder($0) != scope }
    }

    private func flatten(_ folders: [MediaLibrary.Folder]) -> [MediaLibrary.Folder] {
        folders.flatMap { [$0] + flatten($0.children ?? []) }
    }

    private func subtitle(_ items: [MediaItem]) -> String {
        guard library.state == .ready else { return "" }
        if case .folder = scope, !subfolders.isEmpty {
            let all = library.items(in: scope)
            let here = includeSubfolders ? all.count(where: { $0.folder == folderPath }) : items.count
            return "\(here.formatted()) here · \(all.count.formatted()) with subfolders · \(all.reduce(0) { $0 + $1.bytes }.bytes)"
        }
        let count = items.count == 1 ? "1 item" : "\(items.count.formatted()) items"
        return "\(count) · \(items.reduce(0) { $0 + $1.bytes }.bytes)"
    }

    private func keyHandling(_ items: [MediaItem]) -> GridKeys {
        GridKeys(
            focused: $focused,
            clear: { library.selection = [] },
            selectAll: { library.selection = Set(items.map(\.id)) },
            preview: { openViewer(on: (items.first { $0.id == anchor && library.selection.contains($0.id) } ?? selected.first)) },
            open: { selected.forEach { NSWorkspace.shared.open($0.url) } },
            delete: {
                guard !selected.isEmpty else { return }
                if isTrash { deletingNow = selected.compactMap(library.trashed) } else { trash(selected) }
            },
            deleteTitle: isTrash ? "Delete Now…" : deletesOnPhone ? "Delete" : "Move to Recently Deleted",
            copy: { selected.map(\.url) },
            paste: pasteTarget.map { path in { urls in _ = library.drop(urls, onto: .folder(path), server: server, history: history) } }
        )
    }

    private var deleteAllTitle: String {
        let count = library.items(in: scope).count
        return count == 1 ? "Move 1 item to Recently Deleted?" : "Move all \(count.formatted()) items to Recently Deleted?"
    }

    /// Where ⌘V puts files: this folder, when one is shown.
    private var pasteTarget: String? {
        if case .folder(let path) = scope { return path }
        return nil
    }

    private var dialogs: DialogsModifier {
        DialogsModifier(selected: selected, library: library, server: server, history: history,
                        deletingNow: $deletingNow, removing: $removing, naming: $naming)
    }

    // MARK: Actions

    /// The library's own pages delete from the iPhones too; a Folder, Deleted on iPhone and Recently
    /// Deleted are about the drive alone.
    private var deletesOnPhone: Bool {
        switch scope {
        case .all, .large, .onThisDay, .items: true
        default: false
        }
    }

    /// Delete: from the iPhones too on the library's own pages (the backups go to Recently Deleted);
    /// elsewhere, to Recently Deleted.
    private func trash(_ items: [MediaItem]) {
        library.selection = []
        Task {
            history.record(deletesOnPhone ? await library.delete(items, server: server) : await library.trash(items, server: server))
        }
    }

    private func putBack(_ items: [MediaItem]) {
        library.selection = []
        let trashed = items.compactMap(library.trashed)
        Task { history.record(await library.putBack(trashed, server: server)) }
    }

    /// Into a folder, or back to the iPhone's folder for nil.
    private func moveSelected(_ items: [MediaItem], to folder: String?) {
        Task {
            if let folder {
                await library.transfer(items, toFolder: folder, server: server, history: history)
            } else {
                history.record(await library.move(items, to: .phoneFolder, server: server))
            }
        }
    }
}

/// A page's title, subtitle and toolbar, unless it's inside another page.
private struct PageChrome<Toolbar: ToolbarContent>: ViewModifier {
    let embedded: Bool
    let title: String
    let subtitle: String
    @ToolbarContentBuilder var toolbar: () -> Toolbar

    func body(content: Content) -> some View {
        if embedded {
            content
        } else {
            content
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .toolbar(content: toolbar)
        }
    }
}

private struct DialogsModifier: ViewModifier {
    let selected: [MediaItem]
    let library: MediaLibrary
    let server: BackupServer
    let history: FileHistory
    @Binding var deletingNow: [TrashedItem]?
    @Binding var removing: [MediaItem]?
    @Binding var naming: FolderNaming?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(deleteNowTitle, isPresented: Binding(get: { deletingNow != nil }, set: { if !$0 { deletingNow = nil } })) {
                Button("Delete", role: .destructive) {
                    let items = deletingNow ?? []
                    library.selection = []
                    Task { await library.deleteNow(items, server: server) }
                }
            } message: {
                Text("They're deleted from the backup drive for good. This can't be undone.")
            }
            .confirmationDialog(removalTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Ask iPhone to Remove") {
                    let items = removing ?? []
                    Task { history.record(await library.removeFromPhone(items, server: server)) }
                }
            } message: {
                Text("Each is checked against the copy here first. Your iPhone asks you to confirm; removed items go to Recently Deleted there, and stay on this drive.")
            }
            .folderNameAlert($naming, library: library, server: server)
            .alert("Couldn't finish", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                Button("OK") {}
            } message: {
                Text(library.error ?? "")
            }
    }

    private var deleteNowTitle: String {
        let count = deletingNow?.count ?? 0
        return count == 1 ? "Delete this item for good?" : "Delete \(count) items for good?"
    }

    private var removalTitle: String {
        let items = removing ?? []
        let count = library.removable(items).count
        let skipped = items.count - count
        let base = count == 1 ? "Ask iPhone to remove 1 item?" : "Ask iPhone to remove \(count) items?"
        return skipped > 0 ? base + " \(skipped) not on the iPhone or not fully backed up are left out." : base
    }
}

extension BrowserView {
    // MARK: Pieces

    // MARK: Folders

    private var folderPath: String? { if case .folder(let path) = scope { path } else { nil } }

    /// The folders directly inside this one.
    private var subfolders: [MediaLibrary.Folder] {
        guard let folderPath else { return [] }
        func find(_ folders: [MediaLibrary.Folder]) -> MediaLibrary.Folder? {
            for folder in folders {
                if folder.path == folderPath { return folder }
                if folderPath.hasPrefix(folder.path + "/"), let inside = find(folder.children ?? []) { return inside }
            }
            return nil
        }
        return find(library.folders)?.children ?? []
    }

    /// Like Finder: where this folder is (each part goes there), then its subfolders as cards, then a
    /// heading for what's directly in it.
    @ViewBuilder
    private func folderHeader(_ path: String, count: Int) -> some View {
        let parts = path.split(separator: "/").map(String.init)
        VStack(alignment: .leading, spacing: 14) {
            if parts.count > 1 {
                HStack(spacing: 4) {
                    ForEach(parts.indices, id: \.self) { i in
                        if i > 0 { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
                        let target = parts[...i].joined(separator: "/")
                        if i == parts.count - 1 {
                            Label(parts[i], systemImage: "folder.fill").fontWeight(.semibold)
                        } else {
                            Button { openFolder(target) } label: { Label(parts[i], systemImage: "folder") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Go to “\(parts[i])” (⌘↑ goes up one)")
                        }
                    }
                }
                .font(.callout)
                .labelStyle(.titleAndIcon)
            }
            let inside = subfolders
            if !inside.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { showSubfolderCards.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .rotationEffect(.degrees(showSubfolderCards ? 90 : 0))
                        Text("Folders").font(.headline)
                        Text(inside.count.formatted()).font(.callout).foregroundStyle(.secondary)
                        Text(showSubfolderCards ? "Hide" : "Show")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.tint)
                            .padding(.leading, 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showSubfolderCards ? "Hide the folders inside “\(parts.last ?? path)”" : "Show the folders inside “\(parts.last ?? path)”")
                if showSubfolderCards {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(inside) { folder in
                            FolderCard(folder: folder, covers: Array(library.items(in: .folder(folder.path)).prefix(4))) { openFolder(folder.path) }
                                .dropDestination(for: URL.self) { urls, _ in
                                    library.drop(urls, onto: .folder(folder.path), server: server, history: history)
                                }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Text(includeSubfolders ? "In “\(parts.last ?? path)” and its folders" : "In “\(parts.last ?? path)”")
                    .font(.headline)
                    + Text(includeSubfolders ? "" : count == 0 ? "  Nothing directly in it" : "  \(count.formatted()) \(count == 1 ? "item" : "items")")
                    .font(.callout).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .padding(.bottom, 4)
        // ⌘↑: up one folder, as in Finder.
        .background {
            if parts.count > 1 {
                Button("Enclosing Folder") { openFolder(parts.dropLast().joined(separator: "/")) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }

    private var title: String {
        switch scope {
        case .all: "Library"
        case .folder(let path): (path as NSString).lastPathComponent
        case .trash: "Recently Deleted"
        case .large: "Large Files"
        case .deletedOnPhone(let id): "Deleted on \(server.devices.first { $0.id == id }?.name ?? "iPhone")"
        case .onThisDay: "On This Day"
        case .items: "Places"
        }
    }

    /// Hidden while the viewer is open: the toolbar is the viewer's then.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !viewer.isOpen {
            ToolbarItemGroup(placement: .principal) {
                KindPicker(selection: $kind)

                if isFolder {
                    SourcePicker(selection: $folderSourceRaw, everything: "Everything in the Folder")
                } else if isTrash {
                    SourcePicker(selection: $trashSourceRaw, everything: "Everything in Recently Deleted")
                } else if showsSource {
                    SourcePicker(selection: $sourceRaw)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                TileSizeSlider(size: $tileSize)
                if case .folder = scope, !subfolders.isEmpty {
                    Toggle(isOn: $includeSubfolders) {
                        Label("Subfolders", systemImage: includeSubfolders ? "checkmark.square.fill" : "square")
                    }
                    .toggleStyle(.button)
                    .labelStyle(.titleAndIcon)
                    .help(includeSubfolders ? "Showing what's in the subfolders too" : "Show what's in the subfolders too")
                }
                if case .folder(let path) = scope {
                    Button { server.revealInFinder(server.foldersURL.appending(path: path)) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .help("Show this folder in Finder")
                }
                if case .deletedOnPhone(let deviceID) = scope {
                    let all = library.items(in: scope)
                    let phone = server.devices.first { $0.id == deviceID }?.name ?? "the iPhone"
                    Menu {
                        Button("Keep All the Backups") { Task { history.record(await library.keepBackups(all, server: server)) } }
                        Button("Put All Back on \(phone)") { Task { history.record(await library.putBackOnPhone(all, server: server)) } }
                        Divider()
                        Button("Move All to Recently Deleted…") { confirmingDeleteAll = true }
                    } label: {
                        Label("Decide for All", systemImage: "checklist")
                    }
                    .disabled(all.isEmpty)
                    .help("Keep every backup here, put them all back on \(phone), or move them all to Recently Deleted")
                }
                if isTrash {
                    Button("Empty…") { deletingNow = library.trash }
                        .disabled(library.trash.isEmpty)
                        .help("Delete everything in Recently Deleted for good")
                }
            }
        }
    }

    @ViewBuilder
    private func emptyState(isEmpty: Bool) -> some View {
        switch library.state {
        case .loading:
            ProgressView("Reading your library…").controlSize(.large)
        case .unavailable:
            ContentUnavailableView(
                "Backup drive not connected", systemImage: "externaldrive.badge.xmark",
                description: Text("Connect “\(server.location.volumeName)” to see your photos and videos.")
            )
        case .ready where isEmpty:
            switch scope {
            case .all:
                ContentUnavailableView("No photos yet", systemImage: "photo.on.rectangle.angled",
                                       description: Text("Photos and videos appear here as your iPhones back up."))
            case .folder where !subfolders.isEmpty:
                EmptyView() // The subfolders' cards are there, and the header says nothing is directly in it.
            case .folder(let path) where source != .drive && !library.items(in: scope).isEmpty:
                ContentUnavailableView(
                    "Nothing here is on \(sourceName)", systemImage: "iphone.slash",
                    description: Text("“\((path as NSString).lastPathComponent)” has \(library.items(in: scope).count.formatted()) items on the drive. Show Everything in the Folder to see them.")
                )
            case .folder(let path):
                ContentUnavailableView(
                    "“\((path as NSString).lastPathComponent)” is empty", systemImage: "folder",
                    description: Text("Select photos or videos and choose Move To, or drag them onto this folder in the sidebar or the Files panel.")
                )
            case .trash where source != .drive && !library.trash.isEmpty:
                ContentUnavailableView(
                    "Nothing here is on \(sourceName)", systemImage: "iphone.slash",
                    description: Text("Recently Deleted has \(library.trash.count.formatted()) items. Show Everything in Recently Deleted to see them.")
                )
            case .trash:
                ContentUnavailableView("Recently Deleted is empty", systemImage: "trash",
                                       description: Text("Deleted photos and videos wait here, so you can put them back."))
            case .large:
                ContentUnavailableView("No large files", systemImage: "externaldrive",
                                       description: Text("Photos and videos over \(MediaLibrary.largeFileBytes.bytes) show here, biggest first."))
            case .onThisDay:
                ContentUnavailableView("Nothing on this day", systemImage: "calendar.badge.clock",
                                       description: Text("Photos and videos taken on \(Date.now.formatted(.dateTime.month(.wide).day())) in earlier years show here."))
            case .items:
                ContentUnavailableView("Nothing here", systemImage: "map")
            case .deletedOnPhone:
                ContentUnavailableView("Nothing deleted on the iPhone", systemImage: "checkmark.circle",
                                       description: Text("Photos and videos deleted on the iPhone after they were backed up show here, as of its last backup."))
            }
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private func menu(for item: MediaItem) -> some View {
        let targets = library.selection.contains(item.id) ? selected : [item]
        Button("Open") { openViewer(on: item) }
        OpenWithMenu(urls: targets.map(\.url))
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url)) }
        let copies = targets.flatMap(otherFolders(holding:)).map(\.url)
        if !copies.isEmpty {
            Button("Open Copy in Finder") { NSWorkspace.shared.activateFileViewerSelecting(copies) }
        }
        if !isTrash, targets.contains(where: { $0.deviceID == nil }), !server.devices.isEmpty {
            Menu("Send to iPhone") {
                ForEach(server.devices) { device in
                    Button("Send to \(device.name)") { sendToPhone(targets, device) }
                }
            }
        }
        Divider()
        if isTrash {
            Button("Put Back") { putBack(targets) }
            Button("Delete Now…", role: .destructive) { deletingNow = targets.compactMap(library.trashed) }
        } else {
            if case .deletedOnPhone(let deviceID) = scope {
                let phone = server.devices.first { $0.id == deviceID }?.name ?? "iPhone"
                Button("Put Back on \(phone)") { Task { history.record(await library.putBackOnPhone(targets, server: server)) } }
                    .disabled(targets.allSatisfy { library.restoring.contains($0.id) })
                Button(targets.count == 1 ? "Keep the Backup" : "Keep the Backups") {
                    Task { history.record(await library.keepBackups(targets, server: server)) }
                }
                Divider()
            }
            Menu(TransferMode.current == .move ? "Move To" : "Copy To") {
                ForEach(otherFolders, id: \.self) { folder in
                    Button(folder) { moveSelected(targets, to: folder) }
                }
                Button("New Folder…") { naming = .newFolder(moving: targets) }
                if targets.contains(where: { $0.folder != nil && $0.deviceID != nil }) {
                    Divider()
                    Button("Back to iPhone's Folder") { moveSelected(targets, to: nil) }
                }
            }
            if !library.removable(targets).isEmpty {
                Button("Remove from iPhone…") { removing = targets }
            }
            Divider()
            Button("Delete", role: .destructive) { trash(targets) }
        }
    }

    // MARK: Selection

    /// Click selects; ⌘-click toggles; ⇧-click selects a range; a double-click opens it in the viewer.
    private func click(_ item: MediaItem, in items: [MediaItem]) {
        focused = true
        var selection = GridSelection(selected: library.selection, anchor: anchor)
        if selection.click(item.id, in: items.map(\.id)) == .doubleClicked {
            openViewer(on: item)
            return
        }
        library.selection = selection.selected
        anchor = selection.anchor
    }

    /// Opens the viewer on `item`, stepping through this grid.
    private func openViewer(on item: MediaItem?) {
        guard let item else { return }
        let items = items
        guard let start = items.firstIndex(where: { $0.id == item.id }) else { return }
        let devices = Dictionary(server.devices.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        viewer.open(.init(
            urls: items.map(\.url), index: start,
            thumbnailBytes: Dictionary(items.map { ($0.url, $0.bytes) }, uniquingKeysWith: { a, _ in a }),
            date: { items[$0].date },
            name: { items[$0].name },
            coordinate: { index in
                guard let latitude = items[index].latitude, let longitude = items[index].longitude else { return nil }
                return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            },
            info: { index in
                let item = items[index]
                var rows = [MediaViewerHost.InfoRow(label: "Name", value: item.name)]
                if let date = item.date { rows.append(.init(label: "Taken", value: date.formatted(date: .complete, time: .standard))) }
                if item.isVideo, item.duration > 0 {
                    rows.append(.init(label: "Length", value: Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond))))
                }
                rows.append(.init(label: "Size", value: item.bytes.bytes))
                if let folder = item.folder, !folder.isEmpty { rows.append(.init(label: "Folder", value: folder)) }
                let copies = (library.inFolders[item.id] ?? []).filter { $0.folder != item.folder }
                if !copies.isEmpty {
                    rows.append(.init(label: copies.count == 1 ? "Also in" : "Also in Folders", value: copies.map { FolderMark.name($0.folder) }.joined(separator: "\n")))
                }
                let from = item.deviceID.flatMap { devices[$0] }
                switch library.origin(of: item) {
                case .phone: rows.append(.init(label: "Source", value: "On \(from ?? "an iPhone")"))
                case .drive: rows.append(.init(label: "Source", value: from.map { "Only on this drive (from \($0))" } ?? "Only on this drive"))
                }
                rows.append(.init(label: "File", value: item.url.path))
                return rows
            },
            sourceFrame: item.id == anchor ? anchorFrame : nil,
            saveEdit: isTrash ? nil : { [library, server, history] index, copy in
                // Beside the original: in its folder, or its iPhone's own dated folder.
                let path = library.editedCopyFolder(for: items[index], server: server)
                guard let step = await library.copyIn([copy], to: path, server: server) else { return nil }
                history.record(step)
                return path.isEmpty ? server.location.url.lastPathComponent : FolderMark.name(path)
            },
            deleteTitle: isTrash ? nil : deletesOnPhone ? "Delete (from the iPhone too; the backup goes to Recently Deleted)" : "Move to Recently Deleted",
            delete: isTrash ? nil : { [library, server, history, deletesOnPhone] index in
                let item = [items[index]]
                guard let step = deletesOnPhone ? await library.delete(item, server: server) : await library.trash(item, server: server)
                else { return false }
                history.record(step)
                return true
            }
        ))
    }
}

/// What a grid shows, kept between redraws until its key changes.
private final class GridCache {
    struct Key: Hashable {
        var revision: Int
        var scope: MediaLibrary.Scope
        var kind: MediaLibrary.Kind
        var source: String
        var subfolders: Bool
    }
    var key: Key?
    var items: [MediaItem] = []
    var days: [Day<MediaItem>] = []
    var ids: Set<String> = []
}

// MARK: - Tile

private struct MediaTile: View {
    let item: MediaItem
    let selected: Bool
    /// Still on its iPhone, waiting to be deleted there: the iPhone's dot, with a clock.
    let pendingRemoval: SourceBadge.Style?
    /// Top left: days left in Recently Deleted, or the size in Large Files.
    var badge: String? = nil
    /// Bottom right: which iPhone it's on, or that it's only on the drive.
    var source: SourceBadge.Style? = nil
    /// Bottom left: which iPhone it came from.
    var cameFrom: SourceBadge.Style? = nil
    /// Top right: the folders it's also in.
    var folders: [FolderCopies.Copy] = []

    var body: some View {
        ThumbnailView(url: item.url, bytes: item.bytes, cornerRadius: 6, showsName: false)
            .overlay(alignment: .topLeading) {
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !folders.isEmpty { FolderMark(folders: folders).padding(6) }
            }
            .overlay(alignment: .bottom) {
                if item.isVideo || source != nil || cameFrom != nil || pendingRemoval != nil {
                    HStack(spacing: 5) {
                        if let cameFrom { SourceBadge(style: cameFrom) }
                        if item.isVideo {
                            Image(systemName: "play.fill").imageScale(.small)
                            if item.duration > 0 {
                                Text(Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond)))
                            }
                        }
                        Spacer(minLength: 0)
                        if let pendingRemoval {
                            SourceBadge(style: pendingRemoval)
                        } else if let source {
                            SourceBadge(style: source)
                        }
                    }
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6))
                }
            }
            .modifier(SelectedOverlay(selected: selected))
            .contentShape(Rectangle())
            .help(item.name)
    }
}

/// A subfolder on its folder's page: the newest item in it, its name, and how many items it holds.
private struct FolderCard: View {
    let folder: MediaLibrary.Folder
    /// Its newest few items, as a 2×2 grid like a folder's preview.
    let covers: [MediaItem]
    var open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary)
                    if covers.count == 1 {
                        ThumbnailView(url: covers[0].url, bytes: covers[0].bytes, cornerRadius: 10, showsName: false)
                    } else if !covers.isEmpty {
                        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                            ForEach(0..<2, id: \.self) { row in
                                GridRow {
                                    ForEach(0..<2, id: \.self) { column in
                                        let i = row * 2 + column
                                        if i < covers.count {
                                            ThumbnailView(url: covers[i].url, bytes: covers[i].bytes, cornerRadius: 0, showsName: false)
                                        } else {
                                            Rectangle().fill(.quaternary).aspectRatio(1, contentMode: .fit)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 24)
                        .background(Color.imago, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .padding(8)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.imago.opacity(hovering ? 0.8 : 0), lineWidth: 2)
                }
                Text(folder.name).font(.callout.weight(.semibold)).lineLimit(1)
                Text("\(folder.count.formatted()) \(folder.count == 1 ? "item" : "items") · \(folder.bytes.bytes)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open “\(folder.name)”. Drop photos here to put them in it.")
    }
}

/// That an iPhone item is also in folders: a folder in a dark capsule, with how many when it's in
/// more than one. Clicking it shows the file in Finder (a menu of them when there are several).
struct FolderMark: View {
    let folders: [FolderCopies.Copy]

    var body: some View {
        Group {
            if folders.count == 1 {
                Button { Self.reveal(folders[0]) } label: { capsule }
                    .buttonStyle(.plain)
            } else {
                Menu {
                    ForEach(folders, id: \.self) { copy in
                        Button("Show in “\(Self.name(copy.folder))”") { Self.reveal(copy) }
                    }
                } label: { capsule }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
        }
        .help(Self.help(folders))
        .accessibilityLabel(folders.count == 1 ? "Show the copy in Finder" : "Show a copy in Finder")
    }

    private var capsule: some View {
        HStack(spacing: 2) {
            Image(systemName: "folder.fill").font(.system(size: 9, weight: .semibold))
            if folders.count > 1 {
                Text(folders.count.formatted()).font(.system(size: 10, weight: .bold).monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .frame(height: 18)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 1.5)
        .contentShape(Capsule())
    }

    /// "Videos/tennis/2026" → "Videos › tennis › 2026".
    static func name(_ folder: String) -> String {
        folder.replacingOccurrences(of: "/", with: " › ")
    }

    static func reveal(_ copy: FolderCopies.Copy) {
        NSWorkspace.shared.activateFileViewerSelecting([copy.url])
    }

    /// "Also in Videos › tennis › 2026. Click to show it in Finder."
    static func help(_ folders: [FolderCopies.Copy]) -> String {
        let names = folders.map { name($0.folder) }
        return names.count == 1
            ? "Also in \(names[0]). Click to show it in Finder."
            : "Also in:\n" + names.joined(separator: "\n") + "\nClick to show one in Finder."
    }
}

/// Which iPhone an item is on, as a dot in the iPhone's color with its initial, or a drive for
/// what's only on the drive.
struct SourceBadge: View {
    struct Style: Hashable {
        /// The iPhone's initial; nil for the drive.
        var initial: String?
        var color: Color
        var help: String
        /// Still on the iPhone, but waiting to be deleted there: a small clock on the dot.
        var waiting = false
        /// Where it came from, not where it is: drawn as an outlined tag, not a dot.
        var cameFrom = false

        /// `cameFrom`: the iPhone it came from, rather than one it's on (in Recently Deleted).
        /// `waiting`: on the iPhone until it deletes it, as asked.
        @MainActor init(_ origin: MediaLibrary.Origin, server: BackupServer, cameFrom: Bool = false, waiting: Bool = false) {
            switch origin {
            case .phone(let id):
                let name = server.devices.first { $0.id == id }?.name ?? "an iPhone"
                initial = name.first.map { String($0).uppercased() } ?? "?"
                color = server.color(of: id)
                help = cameFrom ? "From \(name)" : waiting ? "On \(name) · waiting to be deleted there" : "On \(name)"
                self.waiting = waiting
                self.cameFrom = cameFrom
            case .drive:
                initial = nil
                color = .black.opacity(0.55)
                help = cameFrom ? "Not from an iPhone" : "Only on the drive"
                self.cameFrom = cameFrom
            }
        }
    }

    let style: Style

    var body: some View {
        if style.cameFrom { origin } else { dot }
    }

    /// Where it came from: a dark tag with an iPhone outline and the initial, edged in the iPhone's
    /// color. Unlike the filled dot (where it is now), it reads as a label, not a place.
    private var origin: some View {
        HStack(spacing: 2) {
            Image(systemName: style.initial == nil ? "externaldrive" : "iphone")
                .font(.system(size: 9, weight: .semibold))
            if let initial = style.initial {
                Text(initial).font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(style.initial == nil ? .white.opacity(0.7) : style.color, lineWidth: 1.5))
        .help(style.help)
    }

    private var dot: some View {
        ZStack {
            Circle().fill(style.color)
            if let initial = style.initial {
                Text(initial).font(.system(size: 10, weight: .bold))
            } else {
                Image(systemName: "externaldrive.fill").font(.system(size: 8, weight: .semibold))
            }
        }
        .foregroundStyle(style.color.ink)
        .frame(width: 18, height: 18)
        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.2))
        .overlay(alignment: .bottomTrailing) {
            if style.waiting {
                Image(systemName: "clock.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 11, height: 11)
                    .background(.black.opacity(0.75), in: Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                    .offset(x: 4, y: 3)
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 1.5)
        .help(style.help)
    }

    /// For the selection bar: "On 007's iPhone", "3 on 007's iPhone, 2 only on the drive".
    /// `cameFrom`: "From 007's iPhone", "3 from 007's iPhone, 2 from elsewhere".
    static func summary(_ origins: [MediaLibrary.Origin], devices: [PairedDevice], cameFrom: Bool = false) -> String {
        var counts: [MediaLibrary.Origin: Int] = [:]
        for origin in origins { counts[origin, default: 0] += 1 }
        func name(_ origin: MediaLibrary.Origin) -> String {
            switch origin {
            case .phone(let id): devices.first { $0.id == id }?.name ?? "an iPhone"
            case .drive: "the drive"
            }
        }
        // iPhones in pairing order, then the drive.
        let order = counts.keys.sorted { a, b in
            let rank = { (o: MediaLibrary.Origin) -> Int in
                if case .phone(let id) = o { return devices.firstIndex { $0.id == id } ?? devices.count }
                return Int.max
            }
            return rank(a) < rank(b)
        }
        let on = cameFrom ? "from" : "on", drive = cameFrom ? "from elsewhere" : "only on the drive"
        if order.count == 1 {
            return order[0] == .drive ? (cameFrom ? "Not from an iPhone" : "Only on the drive") : "\(on.capitalized) \(name(order[0]))"
        }
        return order.map { origin in
            origin == .drive ? "\(counts[origin]!) \(drive)" : "\(counts[origin]!) \(on) \(name(origin))"
        }.joined(separator: ", ")
    }
}

// MARK: - Selection bars

private struct SelectionBar: View {
    @AppStorage(TransferMode.key) private var transferMode = TransferMode.copy.rawValue
    let items: [MediaItem]
    /// Where they're from: "On 007's iPhone", "3 on 007's iPhone, 2 only on the drive".
    let sources: String
    let removable: Int
    let folders: [String]
    /// Copies of these in the folders, for Open Copy in Finder.
    var copies: [URL] = []
    /// iPhones these can be sent to (files not from an iPhone); none hides Send to iPhone.
    var sendable: [PairedDevice] = []
    var send: (PairedDevice) -> Void = { _ in }
    let canPutBack: Bool
    var move: (String?) -> Void
    var newFolder: () -> Void
    var removeFromPhone: () -> Void
    let deleteHelp: String
    var trash: () -> Void
    var clear: () -> Void

    var body: some View {
        FloatingBar(count: items.count, detail: "\(items.reduce(0) { $0 + $1.bytes }.bytes) · \(sources)", clear: clear) {
            Menu {
                ForEach(folders, id: \.self) { folder in
                    Button(folder) { move(folder) }
                }
                if !folders.isEmpty { Divider() }
                Button("New Folder…", action: newFolder)
                if canPutBack {
                    Divider()
                    Button("Back to iPhone's Folder") { move(nil) }
                }
            } label: {
                Label(transferMode == TransferMode.move.rawValue ? "Move To" : "Copy To", systemImage: "folder")
            }
            .menuStyle(.button)
            .fixedSize()
            .help(transferMode == TransferMode.move.rawValue
                  ? "Move into a folder; ones still on an iPhone are removed there (Copy | Move in the toolbar)"
                  : "Copy into a folder (Copy | Move in the toolbar)")

            if !sendable.isEmpty {
                Menu {
                    ForEach(sendable) { device in
                        Button("Send to \(device.name)") { send(device) }
                    }
                } label: {
                    Label("Send to iPhone", systemImage: "iphone.and.arrow.forward")
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Add to the iPhone's Photos library. It goes now if Imago is open on the iPhone, otherwise when it next connects.")
            }

            if !copies.isEmpty {
                Button { NSWorkspace.shared.activateFileViewerSelecting(copies) } label: {
                    Label("Open Copy in Finder", systemImage: "folder.badge.gearshape")
                }
                .help(copies.count == 1 ? "Show the copy in a folder on the drive in Finder" : "Show the \(copies.count) copies in folders on the drive in Finder")
            }

            if removable > 0 {
                Button(action: removeFromPhone) {
                    Label("Remove from iPhone", systemImage: "iphone.slash")
                }
                .help("Free space on the iPhone. These stay on this drive.")
            }

            Button(role: .destructive, action: trash) {
                Label("Delete", systemImage: "trash")
            }
            .help(deleteHelp)
        }
    }
}

private struct TrashSelectionBar: View {
    let items: [MediaItem]
    /// Which iPhones they came from.
    let sources: String
    var putBack: () -> Void
    var deleteNow: () -> Void
    var clear: () -> Void

    var body: some View {
        FloatingBar(count: items.count, detail: "\(items.reduce(0) { $0 + $1.bytes }.bytes) · \(sources)", clear: clear) {
            Button(action: putBack) {
                Label("Put Back", systemImage: "arrow.uturn.backward")
            }
            .help("Return them where they were deleted from")
            Button(role: .destructive, action: deleteNow) {
                Label("Delete Now", systemImage: "trash.slash")
            }
            .help("Delete them for good")
        }
    }
}

// MARK: - Folder names

enum FolderNaming: Identifiable {
    /// A new folder, inside `parent` (nil for the top of Folders), with items to move into it.
    case newFolder(moving: [MediaItem], in: String? = nil)
    /// Renames the folder at this path.
    case rename(String)

    var id: String {
        switch self {
        case .newFolder(_, let parent): "new-\(parent ?? "")"
        case .rename(let path): "rename-\(path)"
        }
    }
}

extension View {
    /// Asks for a Folder's name, to create one (moving `moving` into it) or rename one.
    func folderNameAlert(_ naming: Binding<FolderNaming?>, library: MediaLibrary, server: BackupServer,
                         renamed: @escaping (String) -> Void = { _ in }) -> some View {
        modifier(FolderNameAlert(naming: naming, library: library, server: server, renamed: renamed))
    }
}

private struct FolderNameAlert: ViewModifier {
    @Environment(FileHistory.self) private var history
    @Binding var naming: FolderNaming?
    let library: MediaLibrary
    let server: BackupServer
    var renamed: (String) -> Void
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField("Name", text: $name)
                Button(isRename ? "Rename" : "Create") { commit() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(isRename ? "Its photos and videos stay in it." : "A folder on your backup drive, next to your iPhones' folders.")
            }
            .onChange(of: naming?.id) {
                if case .rename(let old) = naming { name = (old as NSString).lastPathComponent } else { name = "" }
            }
    }

    private var isRename: Bool {
        if case .rename = naming { return true }
        return false
    }

    private var title: String { isRename ? "Rename Folder" : "New Folder" }

    private func commit() {
        let request = naming
        let name = name
        Task {
            switch request {
            case .newFolder(let items, let parent):
                guard let created = await library.createFolder(name, in: parent, server: server) else { return }
                history.record(created.undo)
                if !items.isEmpty { await library.transfer(items, toFolder: created.path, server: server, history: history) }
            case .rename(let old):
                guard let new = await library.renameFolder(old, to: name, server: server) else { return }
                history.record(new.undo)
                renamed(new.path)
            case nil:
                break
            }
        }
    }
}
