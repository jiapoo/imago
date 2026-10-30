import CoreLocation
import ImagoKit
import SwiftUI

enum PhoneSection: Hashable {
    case library, favorites, places, onThisDay
    case mediaType(PhoneMediaType)
    case album(String)
    case duplicates, similar, largeVideos, notBackedUp
    case deleting, queue
}

/// The iPhone's Photos library on the Mac, laid out like the Photos app: the whole library by year,
/// month and day, Favorites, Media Types and Albums, plus tools for freeing space. What's done here
/// shows straight away and is queued for the phone, where the user confirms it.
struct PhoneBrowserView: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaViewerHost.self) private var viewer
    @Environment(MediaLibrary.self) private var library
    @Environment(FileHistory.self) private var history
    let device: PairedDevice
    @State private var model: PhoneLibraryModel
    /// Albums to delete, while the confirmation is up.
    @State private var deletingAlbums: [String]?
    /// What's open.
    @State private var section: PhoneSection = .library
    /// What's selected in the sidebar: one section, or several albums (⌘- or ⇧-click) to act on.
    @State private var sidebarSelection: Set<PhoneSection> = [.library]
    @State private var zoom: LibraryZoom = .all
    /// Places: All, Photos or Videos.
    @State private var placesKind: MediaLibrary.Kind = .all
    @AppStorage("phoneTileSize") private var tileSize = 150.0
    /// Select mode, as in Photos on the iPhone: a click adds an item to the selection or takes it out.
    @State private var selecting = false
    /// Bumped by Select All; the grid on screen selects everything it shows.
    @State private var selectAllRequest = 0

    init(device: PairedDevice) {
        self.device = device
        _model = State(initialValue: PhoneLibraryModel.model(for: device))
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
            case .unavailable:
                ContentUnavailableView("Backup drive not connected", systemImage: "externaldrive.badge.xmark",
                                       description: Text("Connect “\(server.location.volumeName)” to see \(device.name)'s library."))
            case .noSnapshot:
                ContentUnavailableView("Back up once to start", systemImage: "iphone.and.arrow.forward",
                                       description: Text("After \(device.name)'s next backup, its library shows up here."))
            case .ready:
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: 220)
                    Divider()
                    content
                        .id(section)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.phoneSelectMode, selecting ? .on(selectAll: selectAllRequest) : .off)
                }
            }
        }
        .navigationTitle(device.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .task(id: "\(server.catalogRevision)-\(server.libraryRevision[device.id, default: 0])") {
            server.loadPreviews(for: device)
            await model.load(from: server)
        }
        // Files beside its backups that the iPhone doesn't have: an edited copy, for one.
        .task(id: library.revision) {
            model.setUnsynced(library.notSynced(on: device) + library.sending(to: device).filter { $0.folder == nil })
        }
        .onChange(of: section) {
            selecting = false
            if !sidebarSelection.contains(section) { sidebarSelection = [section] }
        }
        .onChange(of: sidebarSelection) {
            if sidebarSelection.count == 1, let only = sidebarSelection.first { section = only }
        }
        .confirmationDialog(deleteAlbumsTitle, isPresented: Binding(
            get: { deletingAlbums != nil }, set: { if !$0 { deletingAlbums = nil } }
        ), titleVisibility: .visible) {
            Button((deletingAlbums?.count ?? 0) > 1 ? "Delete Albums" : "Delete Album", role: .destructive) {
                guard let albums = deletingAlbums else { return }
                if case .album(let open) = section, albums.contains(open) { section = .library }
                PhoneActions(server: server, model: model, device: device, library: library, history: history).deleteAlbums(albums)
            }
        } message: {
            let one = (deletingAlbums?.count ?? 0) == 1
            Text("\(one ? "The album is" : "The albums are") deleted on \(device.name); \(one ? "its" : "their") photos and videos stay in the library, as in Photos. \(device.name) asks you to confirm \(server.liveDevices.contains(device.id) ? "now" : "when you next open Imago on it").")
        }
        .onAppear {
            if let requested = model.requestedSection {
                section = requested
                model.requestedSection = nil
            }
        }
        .onAppear { server.keepDriveAwake(true) }
        .onDisappear {
            model.cancelSimilar()
            server.keepDriveAwake(false)
        }
    }

    private var deleteAlbumsTitle: String {
        guard let albums = deletingAlbums else { return "" }
        return albums.count == 1 ? "Delete “\(albums[0])”?" : "Delete \(albums.count) Albums?"
    }

    /// The albums among these sidebar rows.
    private func albums(in sections: Set<PhoneSection>) -> [String] {
        model.albums.filter { sections.contains(.album($0)) }
    }

    private var subtitle: String {
        guard let takenAt = model.takenAt else { return "iPhone library" }
        let waiting = model.queue.pending.count
        return "\(model.assets.count.formatted()) items · as of \(takenAt.shortRelative)"
            + (waiting > 0 ? " · \(waiting) \(waiting == 1 ? "change" : "changes") waiting" : "")
    }

    /// Hidden while the viewer is open: the toolbar is the viewer's then.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.state == .ready, !viewer.isOpen {
            ToolbarItemGroup(placement: .principal) {
                if section == .places {
                    KindPicker(selection: $placesKind)
                }
                if section == .library {
                    Picker("Show", selection: $zoom) {
                        ForEach(LibraryZoom.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Years, months, or every photo by day")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                ConnectionPill(device: device, isLive: server.liveDevices.contains(device.id))
                TileSizeSlider(size: $tileSize)
                if section.hasGrid {
                    if selecting {
                        Button("Select All") { selectAllRequest += 1 }
                            .help("Select everything here (⌘A)")
                        Button("Cancel") { selecting = false }
                            .help("Leave select mode and deselect")
                    } else {
                        Button("Select") { selecting = true }
                            .help("Select several items with single clicks")
                    }
                }
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Section {
                SectionRow(title: "Library", symbol: "photo.on.rectangle", detail: model.assets.count.formatted()).tag(PhoneSection.library)
                SectionRow(title: "Favorites", symbol: "heart", detail: model.favorites.count.formatted()).tag(PhoneSection.favorites)
                SectionRow(title: "Places", symbol: "map",
                           detail: model.assets.count { $0.metadata.location != nil }.formatted()).tag(PhoneSection.places)
                SectionRow(title: "On This Day", symbol: "calendar.badge.clock",
                           detail: onThisDay.count.formatted()).tag(PhoneSection.onThisDay)
            }
            let types = PhoneMediaType.allCases.filter { model.mediaTypeCounts[$0, default: 0] > 0 }
            if !types.isEmpty {
                Section("Media Types") {
                    ForEach(types) { type in
                        SectionRow(title: type.title, symbol: type.symbol, detail: model.mediaTypeCounts[type, default: 0].formatted())
                            .tag(PhoneSection.mediaType(type))
                    }
                }
            }
            if !model.albums.isEmpty {
                Section("Albums") {
                    ForEach(model.albums, id: \.self) { album in
                        SectionRow(title: album, symbol: "rectangle.stack", detail: model.albumCounts[album, default: 0].formatted())
                            .tag(PhoneSection.album(album))
                    }
                }
            }
            Section("Free Up Space") {
                SectionRow(title: "Duplicates", symbol: "plus.square.on.square", detail: groupDetail(model.duplicates)).tag(PhoneSection.duplicates)
                SectionRow(title: "Similar Shots", symbol: "square.stack.3d.down.right",
                           detail: model.similar.map { groupDetail($0 + model.bursts) } ?? (model.bursts.isEmpty ? "Not scanned" : groupDetail(model.bursts)))
                    .tag(PhoneSection.similar)
                SectionRow(title: "Large Videos", symbol: "film.stack", detail: listDetail(model.largeVideos)).tag(PhoneSection.largeVideos)
                SectionRow(title: "Not Backed Up", symbol: "externaldrive.badge.xmark", detail: model.notBackedUp.count.formatted())
                    .tag(PhoneSection.notBackedUp)
            }
            Section("Waiting for iPhone") {
                SectionRow(title: "To Delete", symbol: "trash", detail: listDetail(model.deleting)).tag(PhoneSection.deleting)
                SectionRow(title: "All Changes", symbol: "iphone.and.arrow.forward",
                           detail: model.queue.pending.isEmpty ? "None" : model.queue.pending.count.formatted())
                    .tag(PhoneSection.queue)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // Right-click an album, or several selected: the menu acts on all of them.
        .contextMenu(forSelectionType: PhoneSection.self) { sections in
            let albums = albums(in: sections)
            if !albums.isEmpty {
                if albums.count == 1 {
                    Button("Open") { sidebarSelection = [.album(albums[0])] }
                    Divider()
                }
                Button(albums.count == 1 ? "Copy Name" : "Copy Names") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(albums.joined(separator: "\n"), forType: .string)
                }
                Divider()
                Button(albums.count == 1 ? "Delete Album…" : "Delete \(albums.count) Albums…", role: .destructive) {
                    deletingAlbums = albums
                }
            }
        }
        // ⌫ deletes the selected albums.
        .onDeleteCommand {
            let albums = albums(in: sidebarSelection)
            if !albums.isEmpty { deletingAlbums = albums }
        }
    }

    /// Taken on today's date in earlier years.
    private var onThisDay: [PhoneAsset] {
        model.assets.filter { MediaLibrary.isOnThisDay($0.metadata.creationDate) }
    }

    private func groupDetail(_ groups: [Cleanup.Group]) -> String {
        groups.isEmpty ? "None" : groups.reduce(0) { $0 + $1.reclaimableBytes }.bytes
    }

    private func listDetail(_ assets: [PhoneAsset]) -> String {
        assets.isEmpty ? "None" : assets.reduce(0) { $0 + $1.bytes }.bytes
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch section {
        case .library:
            LibraryView(model: model, device: device, zoom: $zoom)
        case .places:
            PhonePlacesView(model: model, device: device, kind: placesKind)
        case .onThisDay:
            PhoneGrid(model: model, device: device, assets: onThisDay,
                      empty: ("Nothing on this day", "calendar.badge.clock",
                              "Photos and videos taken on \(Date.now.formatted(.dateTime.month(.wide).day())) in earlier years show here."))
        case .favorites:
            PhoneGrid(model: model, device: device, assets: model.favorites,
                      empty: ("No Favorites", "heart", "Select photos and choose Favorite, or press the period key."))
        case .mediaType(let type):
            PhoneGrid(model: model, device: device, assets: model.assets(of: type), empty: ("No \(type.title)", type.symbol, nil))
        case .album(let album):
            PhoneGrid(model: model, device: device, assets: model.assets(inAlbum: album), album: album,
                      empty: ("“\(album)” is empty", "rectangle.stack", "Select photos anywhere and choose Add to Album."))
        case .duplicates:
            GroupsView(model: model, device: device, groups: model.duplicates,
                       explanation: "Exact copies: the original files are byte-for-byte the same. The copy marked Keep is the largest, which has an edit or a Live Photo's video with it; among copies of the same size, a favorite, in more albums, or the oldest.",
                       emptyTitle: "No duplicates")
        case .similar:
            SimilarView(model: model, device: device)
        case .largeVideos:
            PhoneGrid(model: model, device: device, assets: model.largeVideos, byDay: false,
                      explanation: "Videos over 100 MB, biggest first.", empty: ("No large videos", "film.stack", nil))
        case .notBackedUp:
            PhoneGrid(model: model, device: device, assets: model.notBackedUp,
                      explanation: "On the iPhone but not fully on this Mac yet. They're copied at the next backup; until then they can't be deleted from here.",
                      empty: ("Everything is backed up", "checkmark.circle", nil))
        case .deleting:
            PhoneGrid(model: model, device: device, assets: model.deleting, isDeleting: true,
                      explanation: "Waiting to be deleted from the iPhone. You confirm it there, and they go to Recently Deleted on the iPhone. They stay on this Mac.",
                      empty: ("Nothing waiting to be deleted", "trash", nil))
        case .queue:
            QueueView(model: model, device: device)
        }
    }
}

/// Whether changes reach the phone now or wait for it.
private struct ConnectionPill: View {
    let device: PairedDevice
    let isLive: Bool

    var body: some View {
        Label(isLive ? "Connected" : "Not connected", systemImage: isLive ? "iphone.radiowaves.left.and.right" : "iphone.slash")
            .labelStyle(.titleAndIcon)
            .font(.callout.weight(.medium))
            .foregroundStyle(isLive ? .green : .secondary)
            .padding(.horizontal, 8)
            .help(isLive ? "Imago is open on \(device.name). Changes go to it right away."
                         : "Changes go to \(device.name) when you open Imago on it, or at its next backup.")
    }
}

extension PhoneSection {
    /// Shows a grid of items that can be selected (Select applies).
    var hasGrid: Bool {
        switch self {
        case .similar, .queue, .places: false
        default: true
        }
    }
}

/// Whether the Photos page is in select mode, handed to whichever grid is on screen.
enum PhoneSelectMode: Equatable {
    case off
    /// `selectAll` changes each time Select All is pressed.
    case on(selectAll: Int)

    var isOn: Bool { self != .off }
}

extension EnvironmentValues {
    @Entry var phoneSelectMode: PhoneSelectMode = .off
}

struct SectionRow: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        HStack {
            Label(title, systemImage: symbol).lineLimit(1)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

// MARK: - Library: years, months, days

enum LibraryZoom: String, CaseIterable, Identifiable {
    case years, months, all
    var id: Self { self }
    var title: String {
        switch self {
        case .years: "Years"
        case .months: "Months"
        case .all: "All Photos"
        }
    }
}

private struct LibraryView: View {
    let model: PhoneLibraryModel
    let device: PairedDevice
    @Binding var zoom: LibraryZoom
    /// Where to scroll once the next zoom level shows: a month's ID in Months, a day in All Photos.
    @State private var monthTarget: Int?
    @State private var dayTarget: Date?

    var body: some View {
        switch zoom {
        case .years:
            PeriodGrid(model: model, periods: years, minimum: 260, target: .constant(nil)) { period in
                monthTarget = months.first { $0.year == period.year }?.id
                zoom = .months
            }
        case .months:
            PeriodGrid(model: model, periods: months, minimum: 180, target: $monthTarget) { period in
                dayTarget = period.assets.first?.metadata.creationDate.map { Calendar.current.startOfDay(for: $0) }
                zoom = .all
            }
        case .all:
            PhoneGrid(model: model, device: device, assets: model.libraryAssets, scrollTarget: $dayTarget,
                      empty: ("No photos", "photo.on.rectangle", nil))
        }
    }

    private var years: [Period] {
        Cleanup.byYear(model.libraryAssets).reversed().map { year in
            Period(id: year.id, year: year.year, title: year.year.map(String.init) ?? "No Date", assets: year.assets.reversed())
        }
    }

    private var months: [Period] {
        Cleanup.byMonth(model.libraryAssets).reversed().map { month in
            let title: String = if let year = month.year, let number = month.month,
                                   let date = Calendar.current.date(from: DateComponents(year: year, month: number)) {
                date.formatted(.dateTime.month(.wide).year())
            } else {
                "No Date"
            }
            return Period(id: month.id, year: month.year, title: title, assets: month.assets.reversed())
        }
    }
}

/// A year or a month: its assets newest first.
private struct Period: Identifiable {
    var id: Int
    var year: Int?
    var title: String
    var assets: [PhoneAsset]
}

private struct PeriodGrid: View {
    let model: PhoneLibraryModel
    let periods: [Period]
    let minimum: CGFloat
    @Binding var target: Int?
    var open: (Period) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 14)], spacing: 14) {
                    ForEach(periods) { period in
                        Button { open(period) } label: { card(period) }
                            .buttonStyle(.plain)
                            .id(period.id)
                    }
                }
                .padding(20)
            }
            .onAppear {
                guard let target else { return }
                DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
                self.target = nil
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func card(_ period: Period) -> some View {
        Group {
            if let asset = keyAsset(period), let url = model.files[asset.id] {
                ThumbnailView(url: url, bytes: model.thumbnailBytes[asset.id] ?? 0, cornerRadius: 12, showsName: false)
            } else {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary).aspectRatio(1, contentMode: .fit)
            }
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 2) {
                Text(period.title).font(.title2.bold())
                Text(period.assets.count == 1 ? "1 item" : "\(period.assets.count.formatted()) items").font(.callout)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 4)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom))
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
        }
        .contentShape(Rectangle())
    }

    /// A favorite if there is one, otherwise one from the middle; one with a backed-up copy to show.
    private func keyAsset(_ period: Period) -> PhoneAsset? {
        let shown = period.assets.filter { model.files[$0.id] != nil }
        return shown.first { $0.metadata.isFavorite && !$0.isVideo } ?? (shown.isEmpty ? nil : shown[shown.count / 2])
    }
}

// MARK: - Grid

/// A grid of the phone's assets, by day or in the order given, with Photos-style selection and actions.
struct PhoneGrid: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    @Environment(FileHistory.self) private var history
    @Environment(MediaViewerHost.self) private var viewer
    @Environment(\.phoneSelectMode) private var selectMode
    let model: PhoneLibraryModel
    let device: PairedDevice
    let assets: [PhoneAsset]
    var byDay = true
    /// The album being shown, which offers Remove from Album.
    var album: String? = nil
    /// Showing assets waiting to be deleted, which offers Keep on iPhone.
    var isDeleting = false
    var explanation: String? = nil
    var scrollTarget: Binding<Date?> = .constant(nil)
    var empty: (title: String, symbol: String, detail: String?) = ("Nothing here", "photo", nil)

    @AppStorage("phoneTileSize") private var tileSize = 150.0
    @State private var selection = GridSelection()
    @State private var confirmingDelete = false
    @State private var namingAlbum = false
    /// `assets` by day, worked out when the library changes rather than on every click.
    @State private var days: [Day<PhoneAsset>] = []
    /// Where the anchor's thumbnail is, for the viewer to grow out of.
    @State private var anchorFrame: CGRect?
    /// Where each tile is, for the selection box.
    @State private var tileFrames = TileFrames()
    @FocusState private var focused: Bool

    private var selected: [PhoneAsset] {
        selection.selected.isEmpty ? [] : assets.filter { selection.selected.contains($0.id) }
    }
    private var actions: PhoneActions { PhoneActions(server: server, model: model, device: device, library: library, history: history) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
              VStack(spacing: 0) {
                if let explanation {
                    Text(explanation)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.5), spacing: 4)],
                    spacing: 4, pinnedViews: byDay ? [.sectionHeaders] : []
                ) {
                    if byDay {
                        ForEach(days) { day in
                            Section {
                                ForEach(day.items) { tile($0) }
                            } header: {
                                DayHeader(day: day) { selection.selected.formUnion(day.items.map(\.id)) }
                                    .headerFrame("\(day.id.timeIntervalSinceReferenceDate)", in: tileFrames)
                                    .id(day.id)
                            }
                        }
                    } else {
                        ForEach(assets) { tile($0) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, byDay ? 0 : 12)
                .padding(.bottom, 96)
              }
              .modifier(FillsViewport())
              .modifier(SelectionBox(frames: tileFrames, ids: { Set(assets.map(\.id)) }, selection: $selection.selected))
            }
            .onAppear {
                guard let target = scrollTarget.wrappedValue else { return }
                DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
                scrollTarget.wrappedValue = nil
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
        .modifier(PinchToResize(size: $tileSize))
        .overlay {
            if assets.isEmpty {
                ContentUnavailableView(empty.title, systemImage: empty.symbol, description: empty.detail.map { Text($0) })
            }
        }
        .overlay(alignment: .bottom) { bar }
        .animation(.snappy(duration: 0.25), value: selection.selected.isEmpty)
        .modifier(GridKeys(
            focused: $focused,
            clear: { selection.selected = [] },
            selectAll: { selection.selected = Set(assets.map(\.id)) },
            preview: { openViewer(on: assets.first { $0.id == selection.anchor && selection.selected.contains($0.id) } ?? selected.first) },
            open: { selected.compactMap { model.files[$0.id] }.forEach { NSWorkspace.shared.open($0) } },
            delete: { if !isDeleting, !actions.deletable(selected).isEmpty { confirmingDelete = true } },
            deleteTitle: "Delete from iPhone…",
            copy: { selected.compactMap { model.files[$0.id] } },
            extra: [".": { if !selected.isEmpty { actions.toggleFavorite(selected) } }]
        ))
        // Back from the viewer: the keys work on the grid again.
        .onChange(of: viewer.isOpen) { _, open in if !open { focused = true } }
        .onChange(of: selectMode) { old, new in
            // Select All pressed (the request changed while in select mode), or select mode left.
            if case .on(let request) = new, case .on(let before) = old, request != before {
                selection.selected = Set(assets.map(\.id))
            }
            if new == .off { selection.selected = [] }
        }
        .onAppear { if byDay { days = Day.group(assets) } }
        .onChange(of: model.revision) { if byDay { days = Day.group(assets) } }
        .modifier(PhoneDialogs(actions: actions, selected: selected, confirmingDelete: $confirmingDelete,
                               namingAlbum: $namingAlbum, done: { selection.selected = [] }))
    }

    private func tile(_ asset: PhoneAsset) -> some View {
        let file = model.files[asset.id]
        return PhoneTile(asset: asset, url: file ?? server.previews[device.id]?[asset.id], thumbnailBytes: model.thumbnailBytes[asset.id] ?? 0,
                         selected: selection.selected.contains(asset.id),
                         waiting: model.waiting.contains(asset.id), dimmed: isDeleting,
                         folders: library.inFolders["\(device.id)/\(asset.id)"] ?? [])
            .onTapGesture { click(asset) }
            .contextMenu { menu(for: asset) }
            .onAppear { if file == nil { server.requestPreview(asset.id, on: device) } }
            .reportsViewerSourceFrame(asset.id == selection.anchor, to: $anchorFrame)
            .tileFrame(asset.id, in: tileFrames)
            .onDrag { dragProvider(for: asset) }
    }

    /// Drags the backed-up file, or the whole selection's when it's part of it, into a folder.
    private func dragProvider(for asset: PhoneAsset) -> NSItemProvider {
        let dragged = selection.selected.contains(asset.id) ? selected : [asset]
        DragSession.urls = dragged.compactMap { model.files[$0.id] }
        guard let url = model.files[asset.id] else { return NSItemProvider() }
        return NSItemProvider(object: url as NSURL)
    }

    @ViewBuilder
    private var bar: some View {
        let selected = selected
        if !selected.isEmpty {
            PhoneSelectionBar(actions: actions, selected: selected, album: album, isDeleting: isDeleting,
                              confirmingDelete: $confirmingDelete, namingAlbum: $namingAlbum,
                              clear: { selection.selected = [] })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func menu(for asset: PhoneAsset) -> some View {
        let targets = selection.selected.contains(asset.id) ? selected : [asset]
        if model.files[asset.id] != nil {
            Button("Open") { openViewer(on: asset) }
            OpenWithMenu(urls: targets.compactMap { model.files[$0.id] })
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets.compactMap { model.files[$0.id] }) }
            let copies = actions.folderCopies(targets)
            if !copies.isEmpty {
                Button("Open Copy in Finder") { NSWorkspace.shared.activateFileViewerSelecting(copies) }
            }
            Divider()
        }
        if isDeleting {
            Button("Keep on iPhone") { actions.keep(targets); selection.selected = [] }
        } else {
            Button(targets.allSatisfy(\.metadata.isFavorite) ? "Unfavorite" : "Favorite") { actions.toggleFavorite(targets) }
            Menu("Add to Album") {
                ForEach(model.albums, id: \.self) { name in
                    Button(name) { actions.request(.addToAlbum(name), targets) }
                }
                if !model.albums.isEmpty { Divider() }
                Button("New Album…") { selection.selected = Set(targets.map(\.id)); namingAlbum = true }
            }
            if let album {
                Button("Remove from “\(album)”") { actions.request(.removeFromAlbum(album), targets) }
            }
            let items = actions.libraryItems(targets)
            if !actions.otherPhones.isEmpty, !items.isEmpty {
                Menu("Send to iPhone") {
                    ForEach(actions.otherPhones) { other in
                        Button(sendLabel(items, other)) { actions.send(targets, to: other) }
                    }
                }
            }
            Divider()
            if targets.contains(where: { !$0.isUnsynced }) {
                Button("Delete from iPhone…", role: .destructive) {
                    selection.selected = Set(targets.filter { !$0.isUnsynced }.map(\.id))
                    confirmingDelete = true
                }
                .disabled(actions.deletable(targets).isEmpty)
            }
            let notSynced = targets.filter(\.isUnsynced)
            if !notSynced.isEmpty {
                Button(notSynced.count == 1 ? "Move Not Synced File to Recently Deleted" : "Move \(notSynced.count) Not Synced Files to Recently Deleted",
                       role: .destructive) {
                    let items = actions.libraryItems(notSynced)
                    Task { history.record(await library.trash(items, server: server)) }
                }
            }
        }
    }

    /// Click selects, ⌘-click toggles, ⇧-click selects a range; a double-click opens it in the viewer.
    private func click(_ asset: PhoneAsset) {
        focused = true
        // Select mode: a click adds or removes, as in Photos on the iPhone; nothing opens.
        if selectMode.isOn {
            selection.selected.formSymmetricDifference([asset.id])
            selection.anchor = asset.id
            return
        }
        if selection.click(asset.id, in: assets.map(\.id)) == .doubleClicked {
            openViewer(on: asset)
        }
    }

    /// Opens the viewer on `asset`, stepping through the grid's items that have something to show:
    /// the backed-up file, or the phone's preview until there is one.
    private func openViewer(on asset: PhoneAsset?) {
        guard let asset else { return }
        let previews = server.previews[device.id] ?? [:]
        var urls: [URL] = []
        var ids: [String] = []
        var bytes: [URL: UInt64] = [:]
        var start: Int?
        for item in assets {
            guard let url = model.files[item.id] ?? previews[item.id] else { continue }
            if item.id == asset.id { start = urls.count }
            urls.append(url)
            ids.append(item.id)
            bytes[url] = model.thumbnailBytes[item.id] ?? 0
        }
        guard let start else { return }
        // Looked up when shown, so a favorite made in the viewer shows there at once.
        let model = model, actions = actions
        viewer.open(.init(
            urls: urls, index: start, thumbnailBytes: bytes,
            date: { model.asset(ids[$0])?.metadata.creationDate },
            name: { model.asset(ids[$0])?.metadata.originalFilename ?? "" },
            coordinate: { index in
                model.asset(ids[index])?.metadata.location.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            },
            info: { model.asset(ids[$0]).map(Self.info) ?? [] },
            isFavorite: { model.asset(ids[$0])?.metadata.isFavorite ?? false },
            toggleFavorite: { index in model.asset(ids[index]).map { actions.toggleFavorite([$0]) } },
            sourceFrame: asset.id == selection.anchor ? anchorFrame : nil,
            // Edits are saved as a new file beside the backup, as in Library. The iPhone's photo stays
            // as it is.
            saveEdit: { [library, server, history] index, copy in
                guard let item = model.asset(ids[index]).flatMap({ actions.libraryItems([$0]).first }) else { return nil }
                let path = library.editedCopyFolder(for: item, server: server)
                guard let step = await library.copyIn([copy], to: path, server: server) else { return nil }
                history.record(step)
                return FolderMark.name(path)
            },
            // Only the backed-up file: a preview is too small to edit.
            canEdit: { model.files[ids[$0]] != nil },
            deleteTitle: "Delete from iPhone (the backup goes to Recently Deleted on this Mac)",
            delete: { [library, server, history] index in
                if let file = model.asset(ids[index]), file.isUnsynced {
                    // Not on the iPhone: only the file here goes, to Recently Deleted.
                    let items = library.items.filter { $0.url.path == file.id.dropFirst(PhoneAsset.unsyncedPrefix.count) }
                    guard let step = await library.trash(items, server: server) else { return false }
                    history.record(step)
                    return true
                }
                let id = "\(device.id)/\(ids[index])"
                // Its backup may be in Recently Deleted already: it's still deleted from the iPhone.
                let items = (library.items + library.trash.map(\.item)).filter { $0.id == id }
                guard !items.isEmpty, let step = await library.deleteFromPhoneAndHere(items, server: server) else { return false }
                history.record(step)
                return true
            }
        ))
    }

    /// What the viewer's Info panel shows about an asset.
    private static func info(_ asset: PhoneAsset) -> [MediaViewerHost.InfoRow] {
        let metadata = asset.metadata
        var rows = [MediaViewerHost.InfoRow(label: "Name", value: metadata.originalFilename)]
        if let date = metadata.creationDate {
            rows.append(.init(label: "Taken", value: date.formatted(date: .complete, time: .standard)))
        }
        let kinds = PhoneMediaType.allCases.filter { $0 != .videos && $0.contains(asset) }.map(\.title)
        rows.append(.init(label: "Kind", value: ([asset.isVideo ? "Video" : "Photo"] + kinds).joined(separator: " · ")))
        rows.append(.init(label: "Dimensions", value: "\(metadata.pixelWidth) × \(metadata.pixelHeight)"))
        if asset.isVideo {
            rows.append(.init(label: "Length", value: Duration.seconds(metadata.duration).formatted(.time(pattern: .minuteSecond))))
        }
        if asset.bytes > 0 { rows.append(.init(label: "Size", value: asset.bytes.bytes)) }
        rows.append(.init(label: "On this Mac", value: asset.isBackedUp ? "Backed up" : "Not fully backed up yet"))
        if !metadata.albums.isEmpty {
            rows.append(.init(label: "Albums", value: metadata.albums.joined(separator: ", ")))
        }
        if let location = metadata.location {
            rows.append(.init(label: "Location", value: String(format: "%.5f, %.5f", location.latitude, location.longitude)))
        }
        return rows
    }
}

// MARK: - Tile

/// One photo or video on the phone. Shows the backed-up copy, or a placeholder until there is one.
struct PhoneTile: View {
    let asset: PhoneAsset
    let url: URL?
    /// What the thumbnail is keyed by, shared with the Library page.
    var thumbnailBytes: UInt64 = 0
    let selected: Bool
    var waiting = false
    var dimmed = false
    var badge: String? = nil
    /// Folders its backup is in, or a copy of it.
    var folders: [FolderCopies.Copy] = []

    var body: some View {
        Group {
            if let url {
                ThumbnailView(url: url, bytes: thumbnailBytes, cornerRadius: 6, showsName: false)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary).aspectRatio(1, contentMode: .fit)
                    .overlay { Image(systemName: asset.isVideo ? "video" : "photo").font(.title2).foregroundStyle(.tertiary) }
            }
        }
        .opacity(dimmed ? 0.55 : 1)
        .overlay(alignment: .bottom) { strip }
        .overlay(alignment: .topTrailing) {
            if !folders.isEmpty { FolderMark(folders: folders).padding(6) }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
                if asset.isUnsynced {
                    // On this Mac only, beside the iPhone's backups: not on the iPhone (yet).
                    Label("Not synced", systemImage: "iphone.slash")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                        .foregroundStyle(.white)
                        .help("Only on this Mac, next to \(asset.metadata.originalFilename)'s backup. It isn't on the iPhone.")
                }
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.green, in: Capsule())
                        .foregroundStyle(.white)
                }
                if waiting {
                    Image(systemName: "clock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.orange, in: Circle())
                        .help("A change to this is waiting for the iPhone")
                }
            }
            .padding(6)
        }
        .modifier(SelectedOverlay(selected: selected))
        .contentShape(Rectangle())
        .help(asset.metadata.originalFilename)
    }

    @ViewBuilder
    private var strip: some View {
        let favorite = asset.metadata.isFavorite
        if asset.isVideo || favorite || !asset.isBackedUp || dimmed {
            HStack(spacing: 5) {
                if favorite { Image(systemName: "heart.fill") }
                if dimmed { Image(systemName: "trash.fill") }
                Spacer(minLength: 0)
                if !asset.isBackedUp {
                    Image(systemName: "externaldrive.badge.xmark").help("Not fully backed up yet")
                }
                if asset.isVideo {
                    if asset.metadata.duration > 0 {
                        Text(Duration.seconds(asset.metadata.duration).formatted(.time(pattern: .minuteSecond)))
                    } else {
                        Image(systemName: "play.fill").imageScale(.small)
                    }
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
}

// MARK: - Actions

/// What can be done to the phone's assets. Each one is queued for the phone and shows here straight away.
@MainActor
struct PhoneActions {
    let server: BackupServer
    let model: PhoneLibraryModel
    let device: PairedDevice
    let library: MediaLibrary
    let history: FileHistory

    /// Asks for the change against the assets as they were on the phone, so undoing a waiting change
    /// takes it back instead of queuing its opposite. Recorded for undo: the opposite change, which
    /// takes this one back while it's still waiting.
    func request(_ action: LibraryChange.Action, _ assets: [PhoneAsset]) {
        // Files the iPhone doesn't have can't be changed on it.
        let assets = assets.filter { !$0.isUnsynced }
        guard !assets.isEmpty else { return }
        history.record(step(action, ids: assets.map(\.id)))
    }

    private func step(_ action: LibraryChange.Action, ids: [String]) -> FileHistory.Step? {
        let opposite: LibraryChange.Action
        switch action {
        case .setFavorite(let on): opposite = .setFavorite(!on)
        case .addToAlbum(let title): opposite = .removeFromAlbum(title)
        case .removeFromAlbum(let title): opposite = .addToAlbum(title)
        case .delete, .deleteAlbum, .restore: return nil   // see `delete`, `deleteAlbum`, `MediaLibrary.putBackOnPhone`
        }
        server.request(action, for: model.baseAssets(ids), on: device)
        return FileHistory.Step(name: LibraryChange(action: action, assetIDs: ids).summary) { [self] in
            step(opposite, ids: ids)
        }
    }

    /// Asks the iPhone to delete albums, as Photos does: their photos stay in the library. One undo
    /// takes the requests back while they wait.
    func deleteAlbums(_ titles: [String]) {
        history.record(albumDeletion(titles))
    }

    private func albumDeletion(_ titles: [String]) -> FileHistory.Step? {
        let base = Dictionary(model.base.map { ($0.id, $0.metadata) }, uniquingKeysWith: { a, _ in a })
        let ids = titles.compactMap { server.requestAlbumDeletion($0, on: device, base: base) }
        guard !ids.isEmpty else { return nil }
        let name = titles.count == 1 ? "Delete Album" : "Delete \(titles.count) Albums"
        return FileHistory.Step(name: name) { [self] in
            for id in ids { server.cancelChange(id, on: device) }
            return FileHistory.Step(name: name) { [self] in albumDeletion(titles) }
        }
    }

    /// Deletes them from the iPhone (it keeps them in its own Recently Deleted) and moves the backed-up
    /// copies to Imago's Recently Deleted on the Mac, so Put Back returns them. Undo takes both back.
    func delete(_ assets: [PhoneAsset]) {
        let items = libraryItems(assets, includingDeleted: true)
        guard !items.isEmpty else {
            library.error = "\(assets.count == 1 ? "It isn't" : "They aren't") backed up yet, so Imago doesn't delete \(assets.count == 1 ? "it" : "them") from the iPhone. Back up first, or delete in Photos on the iPhone."
            return
        }
        Task { history.record(await library.deleteFromPhoneAndHere(items, server: server)) }
    }

    /// The library's items for these assets: their backed-up files. With `includingDeleted`, also ones
    /// whose backup is in Recently Deleted.
    func libraryItems(_ assets: [PhoneAsset], includingDeleted: Bool = false) -> [MediaItem] {
        // A file the iPhone doesn't have is known by its path.
        let ids = Set(assets.filter { !$0.isUnsynced }.map { "\(device.id)/\($0.id)" })
        let paths = Set(assets.filter(\.isUnsynced).map { String($0.id.dropFirst(PhoneAsset.unsyncedPrefix.count)) })
        let items = includingDeleted ? library.items + library.trash.map(\.item) : library.items
        return items.filter { ids.contains($0.id) || paths.contains($0.url.path) }
    }

    /// Copies their backed-up files into a folder on the drive, or moves them there and removes them
    /// from the iPhone: the toolbar's Copy | Move (see `MediaLibrary.transfer`).
    func transfer(_ assets: [PhoneAsset], toFolder path: String) {
        let items = libraryItems(assets)
        Task { await library.transfer(items, toFolder: path, server: server, history: history) }
    }

    /// The other iPhones, to send these to.
    var otherPhones: [PairedDevice] { server.devices.filter { $0.id != device.id } }

    /// Adds their backed-up files to another iPhone's Photos library: copied, or with Move deleted
    /// here after (see `MediaLibrary.send`).
    func send(_ assets: [PhoneAsset], to other: PairedDevice) {
        let items = libraryItems(assets)
        Task { history.record(await library.send(items, to: other, server: server)) }
    }

    /// Favorites them all, or unfavorites them if they all are already.
    func toggleFavorite(_ assets: [PhoneAsset]) {
        request(.setFavorite(!assets.allSatisfy(\.metadata.isFavorite)), assets)
    }

    /// The ones that can be deleted from the phone: only what's fully on this Mac.
    func deletable(_ assets: [PhoneAsset]) -> [PhoneAsset] {
        assets.filter { $0.isBackedUp && !$0.isUnsynced }
    }

    func keep(_ assets: [PhoneAsset]) {
        let ids = Set(assets.map(\.id))
        server.keep(ids, on: device)
        history.record(FileHistory.Step(name: "Keep on iPhone") { [self] in
            server.request(.delete, for: model.baseAssets(ids), on: device)
            return FileHistory.Step(name: "Keep on iPhone") { [self] in
                server.keep(ids, on: device)
                return nil
            }
        })
    }

    /// The copies of these in the folders (see `MediaLibrary.inFolders`).
    func folderCopies(_ assets: [PhoneAsset]) -> [URL] {
        assets.flatMap { library.inFolders["\(device.id)/\($0.id)"] ?? [] }.map(\.url)
    }

    /// Every folder on the drive, by path.
    var folders: [String] {
        func flatten(_ folders: [MediaLibrary.Folder]) -> [String] { folders.flatMap { [$0.path] + flatten($0.children ?? []) } }
        return flatten(library.folders)
    }

    /// Imago is open on the phone, so changes reach it now.
    var isLive: Bool { server.liveDevices.contains(device.id) }
}

struct PhoneSelectionBar: View {
    @AppStorage(TransferMode.key) private var transferMode = TransferMode.copy.rawValue
    let actions: PhoneActions
    let selected: [PhoneAsset]
    var album: String? = nil
    var isDeleting = false
    @Binding var confirmingDelete: Bool
    @Binding var namingAlbum: Bool
    var clear: () -> Void

    var body: some View {
        let deletable = actions.deletable(selected)
        let skipped = selected.count - deletable.count
        FloatingBar(count: selected.count,
                    detail: selected.reduce(0) { $0 + $1.bytes }.bytes + (skipped > 0 && !isDeleting ? " · \(skipped) not backed up" : ""),
                    clear: clear) {
            if isDeleting {
                Button {
                    actions.keep(selected)
                    clear()
                } label: {
                    Label("Keep on iPhone", systemImage: "arrow.uturn.backward")
                }
            } else {
                // Files the iPhone doesn't have can be moved or put in Recently Deleted, not changed on it.
                let onPhone = selected.filter { !$0.isUnsynced }
                let notSynced = selected.filter(\.isUnsynced)
                let allFavorites = onPhone.allSatisfy(\.metadata.isFavorite)
                if !onPhone.isEmpty {
                Button { actions.toggleFavorite(selected) } label: {
                    Label(allFavorites ? "Unfavorite" : "Favorite", systemImage: allFavorites ? "heart.slash" : "heart")
                }
                .help("Favorite or unfavorite (.)")
                Menu {
                    ForEach(actions.model.albums, id: \.self) { name in
                        Button(name) { actions.request(.addToAlbum(name), selected) }
                    }
                    if !actions.model.albums.isEmpty { Divider() }
                    Button("New Album…") { namingAlbum = true }
                } label: {
                    Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                }
                .menuStyle(.button)
                .fixedSize()
                }
                Menu {
                    ForEach(actions.folders, id: \.self) { path in
                        Button(path) { actions.transfer(selected, toFolder: path) }
                    }
                    if actions.folders.isEmpty {
                        Text("Make a folder in the Files panel first")
                    }
                } label: {
                    Label(transferMode == TransferMode.move.rawValue ? "Move To" : "Copy To", systemImage: "folder")
                }
                .menuStyle(.button)
                .fixedSize()
                .disabled(deletable.isEmpty && notSynced.isEmpty)
                .help(transferMode == TransferMode.move.rawValue
                      ? "Move into a folder on the drive and remove from the iPhone (Copy | Move in the toolbar)"
                      : "Copy into a folder on the drive; the iPhone keeps them (Copy | Move in the toolbar)")
                let items = actions.libraryItems(selected)
                if !actions.otherPhones.isEmpty {
                    Menu {
                        ForEach(actions.otherPhones) { other in
                            Button(sendLabel(items, other)) { actions.send(selected, to: other) }
                        }
                    } label: {
                        Label("Send to iPhone", systemImage: "iphone.and.arrow.forward")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .disabled(items.isEmpty)
                    .help(items.isEmpty ? "Only items backed up on this Mac can be sent to another iPhone"
                          : "Add to another iPhone's Photos library. With Move, they're deleted from this iPhone after.")
                }
                let copies = actions.folderCopies(selected)
                if !copies.isEmpty {
                    Button { NSWorkspace.shared.activateFileViewerSelecting(copies) } label: {
                        Label("Open Copy in Finder", systemImage: "folder.badge.gearshape")
                    }
                    .help(copies.count == 1 ? "Show the copy in a folder on the drive in Finder" : "Show the \(copies.count) copies in folders on the drive in Finder")
                }
                if let album {
                    Button { actions.request(.removeFromAlbum(album), selected) } label: {
                        Label("Remove from Album", systemImage: "rectangle.stack.badge.minus")
                    }
                }
                if !onPhone.isEmpty {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(deletable.isEmpty)
                    .help(deletable.isEmpty ? "Only items fully backed up on this Mac can be deleted from the iPhone" : "Delete from the iPhone")
                } else {
                    Button(role: .destructive) {
                        let items = actions.libraryItems(notSynced)
                        Task { actions.history.record(await actions.library.trash(items, server: actions.server)) }
                        clear()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .help("Move to Recently Deleted on this Mac. These aren't on the iPhone.")
                }
            }
        }
    }
}

/// The delete confirmation and New Album prompt for a grid.
struct PhoneDialogs: ViewModifier {
    let actions: PhoneActions
    let selected: [PhoneAsset]
    @Binding var confirmingDelete: Bool
    @Binding var namingAlbum: Bool
    var done: () -> Void
    @State private var albumName = ""

    func body(content: Content) -> some View {
        let deletable = actions.deletable(selected)
        let name = actions.device.name
        content
            .confirmationDialog(
                "Delete \(deletable.count.formatted()) \(deletable.count == 1 ? "item" : "items") from \(name)?",
                isPresented: $confirmingDelete, titleVisibility: .visible
            ) {
                Button("Delete from iPhone", role: .destructive) {
                    actions.delete(deletable)
                    done()
                }
            } message: {
                Text(deleteMessage(skipped: selected.count - deletable.count))
            }
            .alert("New Album", isPresented: $namingAlbum) {
                TextField("Album name", text: $albumName)
                Button("Add") {
                    let title = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty { actions.request(.addToAlbum(title), selected) }
                    albumName = ""
                    done()
                }
                Button("Cancel", role: .cancel) { albumName = "" }
            } message: {
                Text(actions.isLive ? "It's made on \(name) right away." : "It's made on \(name) when the change reaches it.")
            }
    }

    private func deleteMessage(skipped: Int) -> String {
        let when = actions.isLive ? "now" : "when you next open Imago on it, or at its next backup"
        var text = "\(actions.device.name) asks you to confirm \(when); then they go to Recently Deleted on the iPhone for 30 days. "
            + "The backed-up copies go to Recently Deleted in Imago on this Mac, where Put Back returns them; each is checked against them first. "
            + "If iCloud Photos is on, they're removed from your other devices too."
        if skipped > 0 { text += " \(skipped) selected \(skipped == 1 ? "item isn't" : "items aren't") fully backed up yet and will be left alone." }
        return text
    }
}
