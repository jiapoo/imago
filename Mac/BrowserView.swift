import AppKit
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

    @State private var kind: MediaLibrary.Kind = .all
    @State private var deviceID: String?
    /// Large Files: only items still on an iPhone.
    @State private var onlyOnPhone = false
    @AppStorage("browserTileSize") private var tileSize = 150.0
    @State private var anchor: MediaItem.ID?
    /// Where the anchor's thumbnail is, for the viewer to grow out of.
    @State private var anchorFrame: CGRect?
    /// Recently Deleted: items to delete for good, while the confirmation is up.
    @State private var deletingNow: [TrashedItem]?
    /// Items to ask their iPhone to remove, while the confirmation is up.
    @State private var removing: [MediaItem]?
    @State private var naming: FolderNaming?
    @FocusState private var focused: Bool

    private var items: [MediaItem] {
        let items = library.items(in: scope, deviceID: deviceID, kind: kind)
        return scope == .large && onlyOnPhone ? items.filter { library.phoneAsset($0) != nil } : items
    }
    private var selected: [MediaItem] {
        library.selection.isEmpty ? [] : items.filter { library.selection.contains($0.id) }
    }
    private var isTrash: Bool { scope == .trash }

    var body: some View {
        let items = items
        grid(items)
            .overlay { emptyState(isEmpty: items.isEmpty) }
            .overlay(alignment: .bottom) { selectionBar }
            .animation(.snappy(duration: 0.25), value: selected.isEmpty)
            .modifier(keyHandling(items))
            .onChange(of: viewer.isOpen) { _, open in if !open { focused = true } }
            .modifier(dialogs)
            .navigationTitle(title)
            .navigationSubtitle(subtitle(items))
            .toolbar { toolbar }
            .task(id: server.catalogRevision) { await library.load(from: server) }
            .onChange(of: scope) { library.selection = []; anchor = nil }
            // Photos and videos open from the backup drive: keep it spinning while the grid is up.
            .onAppear { server.keepDriveAwake(true) }
            .onDisappear { server.keepDriveAwake(false) }
    }

    private func grid(_ items: [MediaItem]) -> some View {
        ScrollView {
            if case .folder = scope { phoneBanner.padding(.horizontal, 16) }
            if isTrash, !items.isEmpty { trashBanner.padding(.horizontal, 16) }
            if case .deletedOnPhone = scope, !items.isEmpty { deletedOnPhoneBanner.padding(.horizontal, 16) }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.5), spacing: 4)],
                spacing: 4, pinnedViews: scope == .large ? [] : [.sectionHeaders]
            ) {
                if scope == .large {
                    // Biggest first, not by day.
                    ForEach(items) { item in tile(item, in: items) }
                } else {
                    ForEach(Day.group(items)) { day in
                        Section {
                            ForEach(day.items) { item in tile(item, in: items) }
                        } header: {
                            DayHeader(day: day) { library.selection.formUnion(day.items.map(\.id)) }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, scope == .large ? 12 : 0)
            .padding(.bottom, 96)
        }
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
        .modifier(PinchToResize(size: $tileSize))
    }

    private func tile(_ item: MediaItem, in items: [MediaItem]) -> some View {
        MediaTile(
            item: item,
            selected: library.selection.contains(item.id),
            onPhone: library.phoneAsset(item) != nil,
            pendingRemoval: library.pendingRemoval.contains(item.id),
            badge: badge(for: item)
        )
        .onTapGesture { click(item, in: items) }
        .contextMenu { menu(for: item) }
        .onDrag { dragProvider(for: item) }
        .reportsViewerSourceFrame(item.id == anchor, to: $anchorFrame)
    }

    /// Recently Deleted: days left. Large Files: the size.
    private func badge(for item: MediaItem) -> String? {
        switch scope {
        case .trash:
            guard let days = library.trashed(item)?.daysLeft(keeping: server.trashDays) else { return nil }
            return days == 1 ? "1 day" : "\(days) days"
        case .large:
            return item.bytes.bytes
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
                    putBack: { putBack(selected) },
                    deleteNow: { deletingNow = selected.compactMap(library.trashed) },
                    clear: { library.selection = [] }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                SelectionBar(
                    items: selected,
                    removable: library.removable(selected).count,
                    folders: otherFolders,
                    canPutBack: selected.contains { $0.folder != nil && $0.deviceID != nil },
                    move: { folder in moveSelected(selected, to: folder) },
                    newFolder: { naming = .newFolder(moving: selected) },
                    removeFromPhone: { removing = selected },
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
                    Text(removable.count == 1 ? "1 item here is still on your \(phones)" : "\(removable.count.formatted()) items here are still on your \(phones)")
                        .font(.headline)
                    Text("Remove them there to free \(removable.reduce(0) { $0 + $1.bytes }.bytes). They stay on this drive.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
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
        Label("Backed up here, but deleted on the iPhone since. They stay in this backup until you decide: keep them, copy or move them into a folder, or delete them here (they go to Recently Deleted first).",
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
            }
        )
    }

    private var dialogs: DialogsModifier {
        DialogsModifier(selected: selected, library: library, server: server, history: history,
                        deletingNow: $deletingNow, removing: $removing, naming: $naming)
    }

    // MARK: Actions

    private func trash(_ items: [MediaItem]) {
        library.selection = []
        Task { history.record(await library.trash(items, server: server)) }
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

    private var title: String {
        switch scope {
        case .all: "Library"
        case .folder(let path): (path as NSString).lastPathComponent
        case .trash: "Recently Deleted"
        case .large: "Large Files"
        case .deletedOnPhone(let id): "Deleted on \(server.devices.first { $0.id == id }?.name ?? "iPhone")"
        }
    }

    /// Hidden while the viewer is open: the toolbar is the viewer's then.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !viewer.isOpen {
            ToolbarItemGroup(placement: .principal) {
                Picker("Show", selection: $kind) {
                    Label("All", systemImage: "square.grid.2x2").tag(MediaLibrary.Kind.all)
                    Label("Photos", systemImage: "photo").tag(MediaLibrary.Kind.photos)
                    Label("Videos", systemImage: "video").tag(MediaLibrary.Kind.videos)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleOnly)
                .help("Show photos, videos or both")

                if scope == .all || scope == .large, server.devices.count > 1 {
                    Picker("iPhone", selection: $deviceID) {
                        Text("All iPhones").tag(String?.none)
                        ForEach(server.devices) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .fixedSize()
                }
                if scope == .large {
                    Toggle("On iPhone", isOn: $onlyOnPhone)
                        .toggleStyle(.button)
                        .help("Only items still on an iPhone: the ones that free space there")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                TileSizeSlider(size: $tileSize)
                if case .folder(let path) = scope {
                    Button { server.revealInFinder(server.foldersURL.appending(path: path)) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .help("Show this folder in Finder")
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
            case .folder(let path):
                ContentUnavailableView(
                    "“\((path as NSString).lastPathComponent)” is empty", systemImage: "folder",
                    description: Text("Select photos or videos and choose Move To, or drag them onto this folder in the sidebar or the Files panel.")
                )
            case .trash:
                ContentUnavailableView("Recently Deleted is empty", systemImage: "trash",
                                       description: Text("Deleted photos and videos wait here, so you can put them back."))
            case .large:
                ContentUnavailableView("No large files", systemImage: "externaldrive",
                                       description: Text("Photos and videos over \(MediaLibrary.largeFileBytes.bytes) show here, biggest first."))
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
        Button("Open in Default App") { targets.forEach { NSWorkspace.shared.open($0.url) } }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url)) }
        Divider()
        if isTrash {
            Button("Put Back") { putBack(targets) }
            Button("Delete Now…", role: .destructive) { deletingNow = targets.compactMap(library.trashed) }
        } else {
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
            info: { index in
                let item = items[index]
                var rows = [MediaViewerHost.InfoRow(label: "Name", value: item.name)]
                if let date = item.date { rows.append(.init(label: "Taken", value: date.formatted(date: .complete, time: .standard))) }
                if item.isVideo, item.duration > 0 {
                    rows.append(.init(label: "Length", value: Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond))))
                }
                rows.append(.init(label: "Size", value: item.bytes.bytes))
                if let folder = item.folder, !folder.isEmpty { rows.append(.init(label: "Folder", value: folder)) }
                if let name = item.deviceID.flatMap({ devices[$0] }) { rows.append(.init(label: "From", value: name)) }
                rows.append(.init(label: "File", value: item.url.path))
                return rows
            },
            sourceFrame: item.id == anchor ? anchorFrame : nil
        ))
    }
}

// MARK: - Tile

private struct MediaTile: View {
    let item: MediaItem
    let selected: Bool
    let onPhone: Bool
    let pendingRemoval: Bool
    /// Top left: days left in Recently Deleted, or the size in Large Files.
    var badge: String? = nil

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
            .overlay(alignment: .bottom) {
                if item.isVideo || onPhone {
                    HStack(spacing: 5) {
                        if item.isVideo {
                            Image(systemName: "play.fill").imageScale(.small)
                            if item.duration > 0 {
                                Text(Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond)))
                            }
                        }
                        Spacer(minLength: 0)
                        if pendingRemoval {
                            Image(systemName: "iphone.slash").help("Waiting to be removed from the iPhone")
                        } else if onPhone {
                            Image(systemName: "iphone").help("Also on the iPhone")
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

// MARK: - Selection bars

private struct SelectionBar: View {
    @AppStorage(TransferMode.key) private var transferMode = TransferMode.copy.rawValue
    let items: [MediaItem]
    let removable: Int
    let folders: [String]
    let canPutBack: Bool
    var move: (String?) -> Void
    var newFolder: () -> Void
    var removeFromPhone: () -> Void
    var trash: () -> Void
    var clear: () -> Void

    var body: some View {
        FloatingBar(count: items.count, detail: items.reduce(0) { $0 + $1.bytes }.bytes, clear: clear) {
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

            if removable > 0 {
                Button(action: removeFromPhone) {
                    Label("Remove from iPhone", systemImage: "iphone.slash")
                }
                .help("Free space on the iPhone. These stay on this drive.")
            }

            Button(role: .destructive, action: trash) {
                Label("Delete", systemImage: "trash")
            }
            .help("Move to Recently Deleted (⌫). ⌘Z puts it back.")
        }
    }
}

private struct TrashSelectionBar: View {
    let items: [MediaItem]
    var putBack: () -> Void
    var deleteNow: () -> Void
    var clear: () -> Void

    var body: some View {
        FloatingBar(count: items.count, detail: items.reduce(0) { $0 + $1.bytes }.bytes, clear: clear) {
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
