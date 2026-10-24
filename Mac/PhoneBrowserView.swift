import ImagoKit
import QuickLook
import SwiftUI

enum PhoneSection: Hashable {
    case library, favorites
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
    let device: PairedDevice
    @State private var model: PhoneLibraryModel
    @State private var section: PhoneSection = .library
    @State private var zoom: LibraryZoom = .all
    @AppStorage("phoneTileSize") private var tileSize = 150.0

    init(device: PairedDevice) {
        self.device = device
        _model = State(initialValue: PhoneLibraryModel(device: device))
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
        .onDisappear { model.cancelSimilar() }
    }

    private var subtitle: String {
        guard let takenAt = model.takenAt else { return "iPhone library" }
        let waiting = model.queue.pending.count
        return "\(model.assets.count.formatted()) items · as of \(takenAt.shortRelative)"
            + (waiting > 0 ? " · \(waiting) \(waiting == 1 ? "change" : "changes") waiting" : "")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.state == .ready {
            ToolbarItemGroup(placement: .principal) {
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
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $section) {
            Section {
                SectionRow(title: "Library", symbol: "photo.on.rectangle", detail: model.assets.count.formatted()).tag(PhoneSection.library)
                SectionRow(title: "Favorites", symbol: "heart", detail: model.favorites.count.formatted()).tag(PhoneSection.favorites)
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
                       explanation: "Exact copies: the original files are byte-for-byte the same. The copy marked Keep is a favorite, in more albums, or the oldest.",
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
            PhoneGrid(model: model, device: device, assets: model.assets, scrollTarget: $dayTarget,
                      empty: ("No photos", "photo.on.rectangle", nil))
        }
    }

    private var years: [Period] {
        Cleanup.byYear(model.assets).reversed().map { year in
            Period(id: year.id, year: year.year, title: year.year.map(String.init) ?? "No Date", assets: year.assets.reversed())
        }
    }

    private var months: [Period] {
        Cleanup.byMonth(model.assets).reversed().map { month in
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
                ThumbnailView(url: url, cornerRadius: 12, showsName: false)
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
    @State private var quickLook: URL?
    @State private var confirmingDelete = false
    @State private var namingAlbum = false
    @FocusState private var focused: Bool

    private var selected: [PhoneAsset] { assets.filter { selection.selected.contains($0.id) } }
    private var actions: PhoneActions { PhoneActions(server: server, model: model, device: device) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
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
                        ForEach(Day.group(assets)) { day in
                            Section {
                                ForEach(day.items) { tile($0) }
                            } header: {
                                DayHeader(day: day) { selection.selected.formUnion(day.items.map(\.id)) }
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
            .onAppear {
                guard let target = scrollTarget.wrappedValue else { return }
                DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
                scrollTarget.wrappedValue = nil
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
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
            preview: preview,
            open: { selected.compactMap { model.files[$0.id] }.forEach { NSWorkspace.shared.open($0) } },
            delete: { if !isDeleting, !actions.deletable(selected).isEmpty { confirmingDelete = true } },
            extra: [".": { if !selected.isEmpty { actions.toggleFavorite(selected) } }]
        ))
        .quickLookPreview($quickLook, in: assets.compactMap { model.files[$0.id] })
        .modifier(PhoneDialogs(actions: actions, selected: selected, confirmingDelete: $confirmingDelete,
                               namingAlbum: $namingAlbum, done: { selection.selected = [] }))
    }

    private func tile(_ asset: PhoneAsset) -> some View {
        let file = model.files[asset.id]
        return PhoneTile(asset: asset, url: file ?? server.previews[device.id]?[asset.id], selected: selection.selected.contains(asset.id),
                         waiting: model.waiting.contains(asset.id), dimmed: isDeleting)
            .onTapGesture { click(asset) }
            .contextMenu { menu(for: asset) }
            .onAppear { if file == nil { server.requestPreview(asset.id, on: device) } }
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
        if let url = model.files[asset.id] {
            Button("Quick Look") { quickLook = url }
            Button("Open Backed-Up Copy") { targets.compactMap { model.files[$0.id] }.forEach { NSWorkspace.shared.open($0) } }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets.compactMap { model.files[$0.id] }) }
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
            Divider()
            Button("Delete from iPhone…", role: .destructive) {
                selection.selected = Set(targets.map(\.id))
                confirmingDelete = true
            }
            .disabled(actions.deletable(targets).isEmpty)
        }
    }

    /// Click selects, ⌘-click toggles, ⇧-click selects a range; a double-click shows it in Quick Look.
    private func click(_ asset: PhoneAsset) {
        focused = true
        if selection.click(asset.id, in: assets.map(\.id)) == .doubleClicked, let url = model.files[asset.id] {
            quickLook = url
        }
    }

    private func preview() {
        if quickLook != nil {
            quickLook = nil
        } else {
            let first = assets.first { $0.id == selection.anchor && selection.selected.contains($0.id) } ?? selected.first
            quickLook = first.flatMap { model.files[$0.id] }
        }
    }
}

// MARK: - Tile

/// One photo or video on the phone. Shows the backed-up copy, or a placeholder until there is one.
struct PhoneTile: View {
    let asset: PhoneAsset
    let url: URL?
    let selected: Bool
    var waiting = false
    var dimmed = false
    var badge: String? = nil

    var body: some View {
        Group {
            if let url {
                ThumbnailView(url: url, bytes: asset.bytes, cornerRadius: 6, showsName: false)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary).aspectRatio(1, contentMode: .fit)
                    .overlay { Image(systemName: asset.isVideo ? "video" : "photo").font(.title2).foregroundStyle(.tertiary) }
            }
        }
        .opacity(dimmed ? 0.55 : 1)
        .overlay(alignment: .bottom) { strip }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
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
                    Text(Duration.seconds(asset.metadata.duration).formatted(.time(pattern: .minuteSecond)))
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

    /// Asks for the change against the assets as they were on the phone, so undoing a waiting change
    /// takes it back instead of queuing its opposite.
    func request(_ action: LibraryChange.Action, _ assets: [PhoneAsset]) {
        server.request(action, for: model.baseAssets(assets.map(\.id)), on: device)
    }

    /// Favorites them all, or unfavorites them if they all are already.
    func toggleFavorite(_ assets: [PhoneAsset]) {
        request(.setFavorite(!assets.allSatisfy(\.metadata.isFavorite)), assets)
    }

    /// The ones that can be deleted from the phone: only what's fully on this Mac.
    func deletable(_ assets: [PhoneAsset]) -> [PhoneAsset] {
        assets.filter(\.isBackedUp)
    }

    func keep(_ assets: [PhoneAsset]) {
        server.keep(Set(assets.map(\.id)), on: device)
    }

    /// Imago is open on the phone, so changes reach it now.
    var isLive: Bool { server.liveDevices.contains(device.id) }
}

struct PhoneSelectionBar: View {
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
                let allFavorites = selected.allSatisfy(\.metadata.isFavorite)
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
                if let album {
                    Button { actions.request(.removeFromAlbum(album), selected) } label: {
                        Label("Remove from Album", systemImage: "rectangle.stack.badge.minus")
                    }
                }
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(deletable.isEmpty)
                .help(deletable.isEmpty ? "Only items fully backed up on this Mac can be deleted from the iPhone" : "Delete from the iPhone")
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
                    actions.request(.delete, deletable)
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
        var text = "They're backed up on this Mac and stay here. \(actions.device.name) asks you to confirm \(when); "
            + "then they go to Recently Deleted on the iPhone for 30 days. If iCloud Photos is on, they're removed from your other devices too."
        if skipped > 0 { text += " \(skipped) selected \(skipped == 1 ? "item isn't" : "items aren't") fully backed up yet and will be left alone." }
        return text
    }
}
