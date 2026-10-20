import AppKit
import PhotoBackupKit
import QuickLook
import SwiftUI

/// The library, or one Folder: a grid of days. Click to select (⌘ and ⇧ to add), double-click to
/// open, Space for Quick Look, Delete for the Trash. Drag items onto a Folder in the sidebar.
struct BrowserView: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    let scope: MediaLibrary.Scope

    @State private var kind: MediaLibrary.Kind = .all
    @State private var deviceID: String?
    @AppStorage("browserTileSize") private var tileSize = 150.0
    @State private var anchor: MediaItem.ID?
    @State private var quickLook: URL?
    @State private var confirmingTrash = false
    @State private var confirmingRemoval = false
    @State private var naming: FolderNaming?
    @FocusState private var focused: Bool

    private var items: [MediaItem] { library.items(in: scope, deviceID: deviceID, kind: kind) }
    private var selected: [MediaItem] { items.filter { library.selection.contains($0.id) } }

    var body: some View {
        let items = items
        grid(items)
            .overlay { emptyState(isEmpty: items.isEmpty) }
            .overlay(alignment: .bottom) { selectionBar }
            .animation(.snappy(duration: 0.25), value: selected.isEmpty)
            .modifier(keyHandling(items))
            .quickLookPreview($quickLook, in: items.map(\.url))
            .modifier(dialogs)
            .navigationTitle(title)
            .navigationSubtitle(subtitle(items))
            .toolbar { toolbar }
            .task(id: server.catalogRevision) { await library.load(from: server) }
            .onChange(of: scope) { library.selection = []; anchor = nil }
    }

    private func grid(_ items: [MediaItem]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.5), spacing: 4)],
                spacing: 4, pinnedViews: [.sectionHeaders]
            ) {
                ForEach(Day.group(items)) { day in
                    Section {
                        ForEach(day.items) { item in tile(item, in: items) }
                    } header: {
                        DayHeader(day: day) { library.selection.formUnion(day.items.map(\.id)) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func tile(_ item: MediaItem, in items: [MediaItem]) -> some View {
        MediaTile(
            item: item,
            selected: library.selection.contains(item.id),
            onPhone: library.phoneAsset(item) != nil,
            pendingRemoval: library.pendingRemoval.contains(item.id)
        )
        .onTapGesture { click(item, in: items) }
        .contextMenu { menu(for: item) }
        .draggable(item.url)
    }

    @ViewBuilder
    private var selectionBar: some View {
        if !selected.isEmpty {
            let selected = selected
            SelectionBar(
                items: selected,
                removable: library.removable(selected).count,
                folders: otherFolders,
                canPutBack: selected.contains { $0.folder != nil && $0.deviceID != nil },
                move: { folder in Task { await library.move(selected, to: folder, server: server) } },
                newFolder: { naming = .newFolder(moving: selected) },
                removeFromPhone: { confirmingRemoval = true },
                trash: { confirmingTrash = true },
                clear: { library.selection = [] }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var otherFolders: [String] {
        library.folders.map(\.name).filter { MediaLibrary.Scope.folder($0) != scope }
    }

    private func subtitle(_ items: [MediaItem]) -> String {
        guard library.state == .ready else { return "" }
        let count = items.count == 1 ? "1 item" : "\(items.count.formatted()) items"
        return "\(count) · \(items.reduce(0) { $0 + $1.bytes }.bytes)"
    }

    private func keyHandling(_ items: [MediaItem]) -> KeyboardModifier {
        KeyboardModifier(
            focused: $focused,
            clear: { library.selection = [] },
            selectAll: { library.selection = Set(items.map(\.id)) },
            preview: previewSelection,
            open: { selected.forEach { NSWorkspace.shared.open($0.url) } },
            trash: { if !selected.isEmpty { confirmingTrash = true } }
        )
    }

    private var dialogs: DialogsModifier {
        DialogsModifier(
            selected: selected, library: library, server: server,
            confirmingTrash: $confirmingTrash, confirmingRemoval: $confirmingRemoval,
            naming: $naming, trashTitle: trashTitle, removalTitle: removalTitle
        )
    }
}

/// Space, Return, Escape, ⌘A and Delete for the grid.
private struct KeyboardModifier: ViewModifier {
    var focused: FocusState<Bool>.Binding
    var clear: () -> Void
    var selectAll: () -> Void
    var preview: () -> Void
    var open: () -> Void
    var trash: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { clear() }
            .focusable()
            .focused(focused)
            .focusEffectDisabled()
            .onAppear { focused.wrappedValue = true }
            .onKeyPress(.space) { preview(); return .handled }
            .onKeyPress(.return) { open(); return .handled }
            .onKeyPress(.escape) { clear(); return .handled }
            .onKeyPress(characters: ["a"]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                selectAll()
                return .handled
            }
            .onDeleteCommand(perform: trash)
    }
}

private struct DialogsModifier: ViewModifier {
    let selected: [MediaItem]
    let library: MediaLibrary
    let server: BackupServer
    @Binding var confirmingTrash: Bool
    @Binding var confirmingRemoval: Bool
    @Binding var naming: FolderNaming?
    let trashTitle: String
    let removalTitle: String

    func body(content: Content) -> some View {
        content
            .confirmationDialog(trashTitle, isPresented: $confirmingTrash) {
                Button("Move to Trash", role: .destructive) {
                    let items = selected
                    Task { await library.trash(items, server: server) }
                }
            } message: {
                Text(selected.contains { library.phoneAsset($0) != nil }
                     ? "They're removed from this backup. Ones still on your iPhone won't be backed up again; remove them there too if you don't want them."
                     : "They're removed from this backup. You can put them back from the Trash.")
            }
            .confirmationDialog(removalTitle, isPresented: $confirmingRemoval) {
                Button("Ask iPhone to Remove") {
                    let items = selected
                    Task { await library.removeFromPhone(items, server: server) }
                }
            } message: {
                Text("Your iPhone shows the request at its next backup and asks you to confirm. Removed items go to Recently Deleted there, and stay here on your Mac.")
            }
            .folderNameAlert($naming, library: library, server: server)
            .alert("Couldn't finish", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                Button("OK") {}
            } message: {
                Text(library.error ?? "")
            }
    }
}

extension BrowserView {
    // MARK: Pieces

    private var title: String {
        switch scope {
        case .all: "Library"
        case .folder(let name): name
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            Picker("Show", selection: $kind) {
                Label("All", systemImage: "square.grid.2x2").tag(MediaLibrary.Kind.all)
                Label("Photos", systemImage: "photo").tag(MediaLibrary.Kind.photos)
                Label("Videos", systemImage: "video").tag(MediaLibrary.Kind.videos)
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleOnly)
            .help("Show photos, videos or both")

            if scope == .all, server.devices.count > 1 {
                Picker("iPhone", selection: $deviceID) {
                    Text("All iPhones").tag(String?.none)
                    ForEach(server.devices) { Text($0.name).tag(Optional($0.id)) }
                }
                .fixedSize()
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            HStack(spacing: 6) {
                Image(systemName: "photo").imageScale(.small).foregroundStyle(.secondary)
                Slider(value: $tileSize, in: 90...300).frame(width: 96).controlSize(.small)
                Image(systemName: "photo").imageScale(.large).foregroundStyle(.secondary)
            }
            .help("Thumbnail size")
            if case .folder(let name) = scope {
                Button { server.revealInFinder(server.foldersURL.appending(path: name)) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Show this folder in Finder")
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
            case .folder(let name):
                ContentUnavailableView(
                    "“\(name)” is empty", systemImage: "folder",
                    description: Text("Select photos or videos in Library and choose Move To, or drag them onto this folder in the sidebar.")
                )
            }
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private func menu(for item: MediaItem) -> some View {
        let targets = library.selection.contains(item.id) ? selected : [item]
        Button("Open") { targets.forEach { NSWorkspace.shared.open($0.url) } }
        Button("Quick Look") { quickLook = item.url }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url)) }
        Divider()
        Menu("Move To") {
            ForEach(library.folders.map(\.name).filter { .folder($0) != scope }, id: \.self) { folder in
                Button(folder) { Task { await library.move(targets, to: folder, server: server) } }
            }
            Button("New Folder…") { naming = .newFolder(moving: targets) }
            if targets.contains(where: { $0.folder != nil && $0.deviceID != nil }) {
                Divider()
                Button("Back to iPhone's Folder") { Task { await library.move(targets, to: nil, server: server) } }
            }
        }
        if !library.removable(targets).isEmpty {
            Button("Remove from iPhone…") {
                library.selection = Set(targets.map(\.id))
                confirmingRemoval = true
            }
        }
        Divider()
        Button("Move to Trash…", role: .destructive) {
            library.selection = Set(targets.map(\.id))
            confirmingTrash = true
        }
    }

    private var trashTitle: String {
        selected.count == 1 ? "Move “\(selected[0].name)” to the Trash?" : "Move \(selected.count) items to the Trash?"
    }

    private var removalTitle: String {
        let count = library.removable(selected).count
        let skipped = selected.count - count
        let base = count == 1 ? "Ask iPhone to remove 1 item?" : "Ask iPhone to remove \(count) items?"
        return skipped > 0 ? base + " \(skipped) not on the iPhone or not fully backed up are left out." : base
    }

    // MARK: Selection

    /// Click selects; ⌘-click toggles; ⇧-click selects a range; a double-click opens.
    private func click(_ item: MediaItem, in items: [MediaItem]) {
        focused = true
        let event = NSApp.currentEvent
        if event?.clickCount == 2 {
            NSWorkspace.shared.open(item.url)
            return
        }
        let modifiers = event?.modifierFlags ?? []
        if modifiers.contains(.shift), let anchor,
           let from = items.firstIndex(where: { $0.id == anchor }), let to = items.firstIndex(where: { $0.id == item.id }) {
            library.selection.formUnion(items[min(from, to)...max(from, to)].map(\.id))
        } else if modifiers.contains(.command) {
            library.selection.formSymmetricDifference([item.id])
            anchor = item.id
        } else {
            library.selection = [item.id]
            anchor = item.id
        }
    }

    private func previewSelection() {
        if quickLook != nil {
            quickLook = nil
        } else {
            quickLook = (items.first { $0.id == anchor && library.selection.contains($0.id) } ?? selected.first)?.url
        }
    }
}

// MARK: - Days

struct Day: Identifiable {
    var date: Date?
    var items: [MediaItem]
    var id: Date { date ?? .distantPast }

    /// Items grouped by the day they were taken, newest first; items without a date last.
    static func group(_ items: [MediaItem]) -> [Day] {
        let calendar = Calendar.current
        var days: [Day] = []
        for item in items {
            let date = item.date.map { calendar.startOfDay(for: $0) }
            if days.last?.date == date {
                days[days.count - 1].items.append(item)
            } else {
                days.append(Day(date: date, items: [item]))
            }
        }
        return days
    }

    var title: String {
        guard let date else { return "No Date" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return date.formatted(.dateTime.day().month(.wide).year())
    }
}

private struct DayHeader: View {
    let day: Day
    var selectAll: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(day.title).font(.title3.weight(.semibold))
            Text(summary).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Select", action: selectAll)
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.94))
        .onHover { hovering = $0 }
    }

    private var summary: String {
        let videos = day.items.count { $0.isVideo }
        let photos = day.items.count - videos
        return [photos > 0 ? "\(photos) \(photos == 1 ? "photo" : "photos")" : nil,
                videos > 0 ? "\(videos) \(videos == 1 ? "video" : "videos")" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Tile

private struct MediaTile: View {
    let item: MediaItem
    let selected: Bool
    let onPhone: Bool
    let pendingRemoval: Bool

    var body: some View {
        ThumbnailView(url: item.url, bytes: item.bytes, cornerRadius: 6, showsName: false)
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
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .shadow(color: .black.opacity(0.25), radius: 2)
                        .padding(6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.15), value: selected)
            .contentShape(Rectangle())
            .help(item.name)
    }
}

// MARK: - Selection bar

private struct SelectionBar: View {
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
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(items.count == 1 ? "1 item" : "\(items.count) items").font(.headline)
                Text(items.reduce(0) { $0 + $1.bytes }.bytes).font(.caption).foregroundStyle(.secondary)
            }
            .frame(minWidth: 70, alignment: .leading)

            Divider().frame(height: 26)

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
                Label("Move To", systemImage: "folder")
            }
            .menuStyle(.button)
            .fixedSize()

            if removable > 0 {
                Button(action: removeFromPhone) {
                    Label("Remove from iPhone", systemImage: "iphone.slash")
                }
                .help("Free space on the iPhone. These stay on this Mac.")
            }

            Button(role: .destructive, action: trash) {
                Label("Trash", systemImage: "trash")
            }

            Button(action: clear) {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Deselect all")
        }
        .controlSize(.large)
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .padding(.bottom, 22)
    }
}

// MARK: - Folder names

enum FolderNaming: Identifiable {
    case newFolder(moving: [MediaItem])
    case rename(String)

    var id: String {
        switch self {
        case .newFolder: "new"
        case .rename(let name): "rename-\(name)"
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
                if case .rename(let old) = naming { name = old } else { name = "" }
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
            case .newFolder(let items):
                if let created = await library.createFolder(name, server: server), !items.isEmpty {
                    await library.move(items, to: created, server: server)
                }
            case .rename(let old):
                if let new = await library.renameFolder(old, to: name, server: server) { renamed(new) }
            case nil:
                break
            }
        }
    }
}
