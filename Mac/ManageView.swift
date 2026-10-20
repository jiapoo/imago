import PhotoBackupKit
import SwiftUI

/// The phone's library as of its last backup, with clean-up suggestions. Changes made here are
/// queued for the phone; nothing happens on it until the user confirms there.
@MainActor @Observable
final class PhoneLibraryModel {
    enum State: Equatable {
        case loading
        /// The backup drive isn't connected.
        case unavailable
        /// The phone hasn't backed up with a version that sends its library list.
        case noSnapshot
        case ready
    }

    let device: PairedDevice
    private(set) var state: State = .loading
    private(set) var takenAt: Date?
    private(set) var assets: [PhoneAsset] = []
    private(set) var files: [String: URL] = [:]
    private(set) var albums: [String] = []
    private(set) var queue = ChangeQueue()

    private(set) var duplicates: [Cleanup.Group] = []
    private(set) var bursts: [Cleanup.Group] = []
    private(set) var similar: [Cleanup.Group]?
    private(set) var similarProgress: Double?
    private(set) var largeVideos: [PhoneAsset] = []
    private(set) var screenshots: [PhoneAsset] = []
    private(set) var years: [Cleanup.Year] = []

    private var similarTask: Task<Void, Never>?

    init(device: PairedDevice) {
        self.device = device
    }

    /// Assets already queued for deletion; suggestions leave them out.
    var queuedForDeletion: Set<String> {
        Set(queue.pending.filter { $0.action == .delete }.flatMap(\.assetIDs))
    }

    var backedUpCount: Int { assets.count { $0.isBackedUp } }

    func load(from server: BackupServer) async {
        guard let store = server.store(for: device) else { state = .unavailable; return }
        queue = await store.changeQueue()
        guard let library = await store.phoneLibrary() else { state = .noSnapshot; return }

        let changed = library.takenAt != takenAt
        takenAt = library.takenAt
        files = library.files
        albums = library.albums.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        assets = library.assets
        let visible = assets.filter { !queuedForDeletion.contains($0.id) }
        duplicates = Cleanup.exactDuplicates(visible)
        bursts = Cleanup.bursts(visible)
        largeVideos = Cleanup.largeVideos(visible)
        screenshots = Cleanup.screenshots(visible)
        years = Cleanup.byYear(visible)
        if let similar {
            // Drop what's been queued since; a fresh snapshot needs a new scan.
            self.similar = changed ? nil : similar.compactMap { group in
                let left = group.assets.filter { !queuedForDeletion.contains($0.id) }
                return left.count > 1 ? Cleanup.Group(assets: left, keep: left.contains(group.keep) ? group.keep : Cleanup.bestToKeep(left)) : nil
            }
        }
        state = .ready
    }

    func findSimilar() {
        similarTask?.cancel()
        similarProgress = 0
        let assets = assets.filter { !queuedForDeletion.contains($0.id) }
        let files = files
        similarTask = Task {
            let groups = await SimilarPhotos.find(in: assets, files: files) { [weak self] in self?.similarProgress = $0 }
            if !Task.isCancelled { similar = groups }
            similarProgress = nil
        }
    }

    func cancelSimilar() {
        similarTask?.cancel()
        similarProgress = nil
    }

    func assets(inAlbum album: String) -> [PhoneAsset] {
        assets.filter { $0.metadata.albums.contains(album) }
    }
}

// MARK: - Screen

enum ManageSection: Hashable {
    case duplicates, similar, largeVideos, screenshots, years, albums, favorites, queue
}

struct ManageView: View {
    @Environment(BackupServer.self) private var server
    let device: PairedDevice
    @State private var model: PhoneLibraryModel
    @State private var section: ManageSection = .duplicates

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
                                       description: Text("After \(device.name)'s next backup, its library shows up here, with suggestions for freeing space."))
            case .ready:
                HStack(spacing: 0) {
                    sectionList
                        .frame(width: 230)
                    Divider()
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(device.name)
        .navigationSubtitle(subtitle)
        .task(id: server.libraryRevision[device.id, default: 0]) { await model.load(from: server) }
        .onDisappear { model.cancelSimilar() }
    }

    private var subtitle: String {
        guard let takenAt = model.takenAt else { return "iPhone library" }
        return "\(model.assets.count.formatted()) items · as of \(takenAt.shortRelative)"
    }

    private var sectionList: some View {
        List(selection: $section) {
            Section("Free up space") {
                SectionRow(title: "Duplicates", symbol: "plus.square.on.square",
                           detail: groupDetail(model.duplicates)).tag(ManageSection.duplicates)
                SectionRow(title: "Similar Shots", symbol: "square.stack.3d.down.right",
                           detail: model.similar.map { groupDetail($0 + model.bursts) } ?? (model.bursts.isEmpty ? "Not scanned" : groupDetail(model.bursts)))
                    .tag(ManageSection.similar)
                SectionRow(title: "Large Videos", symbol: "film.stack",
                           detail: listDetail(model.largeVideos)).tag(ManageSection.largeVideos)
                SectionRow(title: "Screenshots", symbol: "camera.viewfinder",
                           detail: listDetail(model.screenshots)).tag(ManageSection.screenshots)
                SectionRow(title: "By Year", symbol: "calendar",
                           detail: "\(model.years.count) years").tag(ManageSection.years)
            }
            Section("Organize") {
                SectionRow(title: "Albums", symbol: "rectangle.stack",
                           detail: "\(model.albums.count)").tag(ManageSection.albums)
                SectionRow(title: "Favorites", symbol: "heart",
                           detail: "\(model.assets.count { $0.metadata.isFavorite })").tag(ManageSection.favorites)
            }
            Section {
                SectionRow(title: "Waiting for iPhone", symbol: "iphone.and.arrow.forward",
                           detail: model.queue.pending.isEmpty ? "None" : "\(model.queue.pending.count)")
                    .tag(ManageSection.queue)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .duplicates:
            GroupsView(model: model, device: device, groups: model.duplicates,
                       explanation: "Exact copies: the original files are byte-for-byte the same. The copy marked Keep is a favorite, in more albums, or the oldest.",
                       emptyTitle: "No duplicates")
        case .similar:
            SimilarView(model: model, device: device)
        case .largeVideos:
            AssetGridView(model: model, device: device, assets: model.largeVideos,
                          explanation: "Videos over 100 MB, biggest first.", emptyTitle: "No large videos")
        case .screenshots:
            AssetGridView(model: model, device: device, assets: model.screenshots,
                          explanation: "Screenshots and screen recordings, newest first.", emptyTitle: "No screenshots")
        case .years:
            YearsView(model: model, device: device)
        case .albums:
            AlbumsView(model: model, device: device)
        case .favorites:
            AssetGridView(model: model, device: device, assets: model.assets.filter { $0.metadata.isFavorite }.reversed(),
                          explanation: "Favorites on the iPhone, newest first.", emptyTitle: "No favorites", inFavorites: true)
        case .queue:
            QueueView(model: model, device: device)
        }
    }

    private func groupDetail(_ groups: [Cleanup.Group]) -> String {
        groups.isEmpty ? "None" : groups.reduce(0) { $0 + $1.reclaimableBytes }.bytes
    }

    private func listDetail(_ assets: [PhoneAsset]) -> String {
        assets.isEmpty ? "None" : assets.reduce(0) { $0 + $1.bytes }.bytes
    }
}

private struct SectionRow: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

// MARK: - Selection and actions

/// The bottom bar: what's selected, and what to do with it on the phone.
private struct ActionBar: View {
    @Environment(BackupServer.self) private var server
    let model: PhoneLibraryModel
    let device: PairedDevice
    @Binding var selection: Set<String>
    var album: String? = nil
    var inFavorites = false
    @State private var confirmingDelete = false
    @State private var naming = false
    @State private var newAlbum = ""

    private var selected: [PhoneAsset] { model.assets.filter { selection.contains($0.id) } }
    private var deletable: [PhoneAsset] { selected.filter(\.isBackedUp) }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(selection.isEmpty ? "Nothing selected" : "\(selection.count.formatted()) selected")
                    .font(.headline)
                if !selection.isEmpty {
                    Text(deletable.count < selected.count
                         ? "\(deletable.reduce(0) { $0 + $1.bytes }.bytes) · \(selected.count - deletable.count) not backed up yet"
                         : deletable.reduce(0) { $0 + $1.bytes }.bytes)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !selection.isEmpty {
                Button("Deselect") { selection = [] }
            }
            if let album {
                Button("Remove from “\(album)”") { queue(.removeFromAlbum(album)) }
                    .disabled(selection.isEmpty)
            }
            Menu {
                ForEach(model.albums, id: \.self) { name in
                    Button(name) { queue(.addToAlbum(name)) }
                }
                if !model.albums.isEmpty { Divider() }
                Button("New Album…") { newAlbum = ""; naming = true }
            } label: {
                Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
            }
            .fixedSize()
            .disabled(selection.isEmpty)
            Button {
                queue(.setFavorite(!inFavorites))
            } label: {
                Label(inFavorites ? "Unfavorite" : "Favorite", systemImage: inFavorites ? "heart.slash" : "heart")
            }
            .disabled(selection.isEmpty)
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete from iPhone…", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(deletable.isEmpty)
            .help("Only items fully backed up on this Mac can be deleted")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .confirmationDialog(
            "Delete \(deletable.count.formatted()) \(deletable.count == 1 ? "item" : "items") from \(device.name)?",
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Ask iPhone to Delete", role: .destructive) { queue(.delete) }
        } message: {
            Text(deleteMessage)
        }
        .alert("New Album", isPresented: $naming) {
            TextField("Album name", text: $newAlbum)
            Button("Add") {
                let name = newAlbum.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { queue(.addToAlbum(name)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The album is made on \(device.name) when you approve the change there.")
        }
    }

    private var deleteMessage: String {
        var text = "They're backed up on this Mac and stay here. Next time \(device.name) backs up, it asks you to confirm; "
            + "then they go to Recently Deleted on the iPhone for 30 days. If iCloud Photos is on, they're removed from your other devices too."
        let skipped = selected.count - deletable.count
        if skipped > 0 { text += " \(skipped) selected \(skipped == 1 ? "item isn't" : "items aren't") fully backed up yet and will be left alone." }
        return text
    }

    private func queue(_ action: LibraryChange.Action) {
        server.request(action, for: selected, on: device)
        selection = []
    }
}

/// One photo or video, selectable, with what matters for cleaning up.
private struct AssetTile: View {
    let asset: PhoneAsset
    let url: URL?
    let selected: Bool
    var badge: String? = nil

    var body: some View {
        ZStack {
            if let url {
                ThumbnailView(url: url, cornerRadius: 8)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary).aspectRatio(1, contentMode: .fit)
                    .overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
            }
        }
        .overlay(alignment: .topLeading) {
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.green, in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, selected ? Color.accentColor : .black.opacity(0.25))
                .padding(6)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 4) {
                if asset.metadata.isFavorite { Image(systemName: "heart.fill") }
                if asset.isVideo { Text(Duration.seconds(asset.metadata.duration).formatted(.time(pattern: .minuteSecond))) }
                if !asset.isBackedUp { Image(systemName: "icloud.slash").help("Not fully backed up yet") }
                Spacer(minLength: 0)
                if asset.bytes > 0 { Text(asset.bytes.bytes) }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0)
        }
        .contentShape(Rectangle())
    }
}

private struct AssetGridView: View {
    let model: PhoneLibraryModel
    let device: PairedDevice
    let assets: [PhoneAsset]
    let explanation: String
    let emptyTitle: String
    var album: String? = nil
    var inFavorites = false
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if assets.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "checkmark.circle")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(explanation).foregroundStyle(.secondary)
                            Spacer()
                            Button("Select All") { selection = Set(assets.map(\.id)) }
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                            ForEach(assets) { asset in
                                AssetTile(asset: asset, url: model.files[asset.id], selected: selection.contains(asset.id))
                                    .onTapGesture { selection.formSymmetricDifference([asset.id]) }
                                    .contextMenu { openMenu(asset) }
                            }
                        }
                    }
                    .padding(20)
                }
            }
            ActionBar(model: model, device: device, selection: $selection, album: album, inFavorites: inFavorites)
        }
        .onChange(of: assets.map(\.id)) { _, ids in selection.formIntersection(ids) }
    }

    @ViewBuilder
    private func openMenu(_ asset: PhoneAsset) -> some View {
        if let url = model.files[asset.id] {
            Button("Open Backed-Up Copy") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

/// Sets of near-identical items, one per row, the suggested keeper first.
private struct GroupsView: View {
    let model: PhoneLibraryModel
    let device: PairedDevice
    let groups: [Cleanup.Group]
    let explanation: String
    let emptyTitle: String
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if groups.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "checkmark.circle")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            Text(explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Select All Extras") { selection = Set(groups.flatMap(\.extras).filter(\.isBackedUp).map(\.id)) }
                        }
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(group.keep.metadata.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Undated")
                                        .font(.callout.weight(.medium))
                                    Text("\(group.assets.count) items · \(group.reclaimableBytes.bytes) extra")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                }
                                ScrollView(.horizontal) {
                                    HStack(spacing: 10) {
                                        ForEach([group.keep] + group.extras) { asset in
                                            AssetTile(asset: asset, url: model.files[asset.id], selected: selection.contains(asset.id),
                                                      badge: asset.id == group.keep.id ? "KEEP" : nil)
                                                .frame(width: 130)
                                                .onTapGesture { selection.formSymmetricDifference([asset.id]) }
                                        }
                                    }
                                }
                                .scrollIndicators(.never)
                            }
                            .card(padding: 14)
                        }
                    }
                    .padding(20)
                }
            }
            ActionBar(model: model, device: device, selection: $selection)
        }
    }
}

private struct SimilarView: View {
    let model: PhoneLibraryModel
    let device: PairedDevice

    var body: some View {
        if let progress = model.similarProgress {
            VStack(spacing: 14) {
                ProgressView(value: progress).frame(width: 280)
                Text("Comparing photos taken close together…").foregroundStyle(.secondary)
                Button("Stop") { model.cancelSimilar() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let similar = model.similar {
            GroupsView(model: model, device: device, groups: model.bursts + similar,
                       explanation: "Shots of the same moment, and bursts. Keep marks the favorite, or the best-looking one by the Mac's photo analysis.",
                       emptyTitle: "No similar shots")
        } else {
            VStack(spacing: 14) {
                Image(systemName: "square.stack.3d.down.right").font(.system(size: 44)).foregroundStyle(.tint)
                Text("Find similar shots").font(.title2.bold())
                Text("The Mac compares photos taken within a minute of each other, using the backed-up copies. Nothing leaves this Mac.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
                Button("Scan \(model.backedUpCount.formatted()) Photos") { model.findSimilar() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                if !model.bursts.isEmpty {
                    Text("\(model.bursts.count) bursts are already listed once you scan.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct YearsView: View {
    let model: PhoneLibraryModel
    let device: PairedDevice
    @State private var year: Int?

    var body: some View {
        let years = model.years
        let current = years.first { $0.id == year } ?? years.first
        VStack(spacing: 0) {
            if let current {
                Picker("Year", selection: Binding(get: { current.id }, set: { year = $0 })) {
                    ForEach(years) { y in
                        Text(y.year.map(String.init) ?? "Undated").tag(y.id)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
                AssetGridView(model: model, device: device, assets: current.assets,
                              explanation: "\(current.assets.count.formatted()) items · \(current.bytes.bytes) on the iPhone",
                              emptyTitle: "Nothing from this year")
                    .id(current.id)
            } else {
                ContentUnavailableView("No photos", systemImage: "calendar")
            }
        }
    }
}

private struct AlbumsView: View {
    let model: PhoneLibraryModel
    let device: PairedDevice
    @State private var album: String?

    var body: some View {
        HStack(spacing: 0) {
            List(model.albums, id: \.self, selection: $album) { name in
                HStack {
                    Text(name).lineLimit(1)
                    Spacer()
                    Text("\(model.assets(inAlbum: name).count)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 210)
            Divider()
            if let album = album ?? model.albums.first {
                AssetGridView(model: model, device: device, assets: model.assets(inAlbum: album),
                              explanation: "In “\(album)” on the iPhone. To add photos, select them in any list and choose Add to Album.",
                              emptyTitle: "This album is empty", album: album)
                    .id(album)
            } else {
                ContentUnavailableView("No albums", systemImage: "rectangle.stack",
                                       description: Text("Select photos in any list and choose Add to Album › New Album."))
            }
        }
    }
}

private struct QueueView: View {
    @Environment(BackupServer.self) private var server
    let model: PhoneLibraryModel
    let device: PairedDevice

    var body: some View {
        List {
            Section {
                if model.queue.pending.isEmpty {
                    Text("Nothing waiting.").foregroundStyle(.secondary)
                }
                ForEach(model.queue.pending) { change in
                    HStack(spacing: 12) {
                        Image(systemName: change.symbol).foregroundStyle(change.action == .delete ? .red : .accentColor).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.summary)
                            Text("Queued \(change.createdAt.shortRelative)" + (change.bytes.map { " · frees about \($0.bytes)" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") { server.cancel(change, on: device) }
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text("Waiting for \(device.name)")
            } footer: {
                Text("These go to the iPhone at its next backup. Open Photo Backup on the iPhone to review and approve them; nothing changes until you do.")
            }

            if !model.queue.done.isEmpty {
                Section("Done") {
                    ForEach(model.queue.done) { done in
                        HStack(spacing: 12) {
                            Image(systemName: done.report.outcome == .applied ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(done.report.outcome == .applied ? .green : .secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(done.change.summary)
                                Text(outcome(done.report)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func outcome(_ report: ChangeReport) -> String {
        let when = report.date.shortRelative
        return switch report.outcome {
        case .applied: "Done on the iPhone \(when)"
        case .declined: "Declined on the iPhone \(when)"
        case .failed: "Couldn't be done \(when)" + (report.detail.map { ": \($0)" } ?? "")
        }
    }
}
