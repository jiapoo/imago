import Charts
import ImagoKit
import SwiftUI

/// One iPhone at a glance: whether it's backed up, what's on it, how it splits between photos and
/// videos, how it grew over the years, and how much could be freed on it. No photos here: those are
/// on its Photos page, which every part of this page opens.
struct DeviceView: View {
    @Environment(BackupServer.self) private var server
    let device: PairedDevice
    /// Opens this iPhone's Photos page, at a section if given.
    var openPhotos: (PhoneSection?) -> Void
    @State private var model: PhoneLibraryModel
    @State private var confirmingRemove = false
    @State private var renaming = false
    @State private var newName = ""

    init(device: PairedDevice, openPhotos: @escaping (PhoneSection?) -> Void) {
        self.device = device
        self.openPhotos = openPhotos
        _model = State(initialValue: PhoneLibraryModel.model(for: device))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                numbers
                if model.state == .ready {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 22, alignment: .top)], spacing: 22) {
                        SpaceCard(model: model)
                        YearsCard(model: model)
                    }
                    FreeUpSpaceCard(model: model, device: device, open: openPhotos)
                    ContentsCard(model: model, open: openPhotos)
                    if !model.queue.pending.isEmpty || !model.queue.done.isEmpty {
                        ChangesCard(model: model, device: device) { openPhotos(.queue) }
                    }
                } else {
                    waiting
                }
                footer
            }
            .padding(32)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(device.name)
        .task(id: "\(server.catalogRevision)-\(server.libraryRevision[device.id, default: 0])") { await model.load(from: server) }
        .confirmationDialog("Remove “\(device.name)”?", isPresented: $confirmingRemove) {
            Button("Remove iPhone", role: .destructive) { server.remove(device) }
        } message: {
            Text("It can't back up to this Mac until you pair it again. Its photos stay in the backup folder.")
        }
        .alert("Rename iPhone", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { server.rename(device, to: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The folder name stays the same.")
        }
    }

    // MARK: Hero

    private var hero: some View {
        let session = server.session(for: device)
        return HStack(alignment: .center, spacing: 22) {
            ZStack {
                Circle().fill(.white.opacity(0.18))
                Image(systemName: session == nil ? "iphone" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 34, weight: .medium))
                    .symbolEffect(.rotate, options: .repeating, isActive: session != nil)
            }
            .frame(width: 76, height: 76)
            VStack(alignment: .leading, spacing: 10) {
                Text(device.name)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                HStack(spacing: 8) {
                    ForEach(chips, id: \.text) { chip in
                        Label(chip.text, systemImage: chip.symbol)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 10) {
                Button { openPhotos(nil) } label: {
                    Label("Open Photos", systemImage: "photo.stack")
                        .font(.headline)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.white, in: Capsule())
                        .foregroundStyle(Color.imago)
                }
                .buttonStyle(.plain)
                Menu {
                    Button("Rename…") { newName = device.name; renaming = true }
                    Button("Show Folder in Finder") { server.revealInFinder(server.folderURL(for: device)) }
                        .disabled(!server.location.isAvailable)
                    Divider()
                    Button("Remove iPhone…", role: .destructive) { confirmingRemove = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.18), in: Circle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .foregroundStyle(.white)
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [Color.imago, Color.imago.mix(with: .black, by: 0.35)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(alignment: .topTrailing) {
                    // A soft glow, for depth.
                    Circle().fill(.white.opacity(0.10)).frame(width: 260).blur(radius: 40).offset(x: 60, y: -110)
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Color.imago.opacity(0.25), radius: 18, y: 8)
        }
    }

    private var chips: [(text: String, symbol: String)] {
        let summary = server.summaries[device.id]
        var chips: [(String, String)] = []
        if let session = server.session(for: device) {
            chips.append((session.total == 0 ? "Comparing libraries…" : "Backing up \(session.received) of \(session.total)", "arrow.triangle.2.circlepath"))
        } else if summary?.isPartial == true {
            chips.append(("Backup not finished", "exclamationmark.circle"))
        } else if model.state == .ready, model.backedUpCount == model.base.count, !model.base.isEmpty {
            chips.append(("All backed up", "checkmark.circle.fill"))
        }
        chips.append(server.liveDevices.contains(device.id) ? ("Imago open on it", "dot.radiowaves.left.and.right") : ("Not connected", "wifi.slash"))
        if let last = summary?.lastBackup { chips.append(("Last backup \(last.shortRelative)", "clock")) }
        return chips
    }

    // MARK: Numbers

    private var numbers: some View {
        let summary = server.summaries[device.id]
        let ready = model.state == .ready
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
            NumberTile(title: "On the iPhone", value: ready ? model.base.count.formatted() : "–",
                       detail: ready ? "\(model.base.count(where: \.isVideo).formatted()) videos" : nil, symbol: "iphone")
            NumberTile(title: "Backed up", value: ready ? backedUpText : "–",
                       detail: ready ? notBackedUpText : nil, symbol: "checkmark.shield")
            NumberTile(title: "On the backup drive", value: (summary?.totalBytes ?? 0).bytes,
                       detail: "\((summary?.fileCount ?? 0).formatted()) files", symbol: "externaldrive")
            NumberTile(title: "Albums", value: ready ? model.albums.count.formatted() : "–",
                       detail: ready ? "\(model.favorites.count.formatted()) favorites" : nil, symbol: "rectangle.stack")
        }
    }

    private var backedUpText: String {
        let total = model.base.count
        guard total > 0 else { return "–" }
        let share = Double(model.backedUpCount) / Double(total)
        return share >= 0.9995 ? "100%" : share.formatted(.percent.precision(.fractionLength(0...1)))
    }

    private var notBackedUpText: String {
        let left = model.base.count - model.backedUpCount
        return left == 0 ? "Everything" : "\(left.formatted()) to go"
    }

    private var waiting: some View {
        ContentUnavailableView(
            model.state == .unavailable ? "Backup drive not connected" : "Nothing to show yet",
            systemImage: model.state == .unavailable ? "externaldrive.badge.xmark" : "iphone.and.arrow.forward",
            description: Text(model.state == .unavailable
                              ? "Connect “\(server.location.volumeName)” to see what's on \(device.name)."
                              : "After \(device.name)'s next backup, what's on it shows here.")
        )
        .modernCard()
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(server.location.displayPath + "/" + device.folder)
                .lineLimit(1).truncationMode(.middle)
            Text("· paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))")
            Spacer()
            Button("Show in Finder") { server.revealInFinder(server.folderURL(for: device)) }
                .buttonStyle(.link)
                .disabled(!server.location.isAvailable)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }
}

// MARK: - Pieces

extension View {
    /// The page's cards: a soft panel with a hairline edge.
    func modernCard(padding: CGFloat = 22) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            .shadow(color: .black.opacity(0.04), radius: 12, y: 4)
    }
}

/// A card's title: a small icon and a heading, with an optional action on the right.
private struct CardTitle<Trailing: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.imago)
                .frame(width: 26, height: 26)
                .background(Color.imago.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title).font(.headline)
            Spacer()
            trailing
        }
    }
}

extension CardTitle where Trailing == EmptyView {
    init(title: String, symbol: String) {
        self.init(title: title, symbol: symbol) { EmptyView() }
    }
}

private struct NumberTile: View {
    let title: String
    let value: String
    let detail: String?
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .modernCard(padding: 18)
    }
}

// MARK: - Space: videos vs photos

/// The two kinds' share of the drive space, as one bar split in two, with the values written out.
private struct SpaceCard: View {
    let model: PhoneLibraryModel

    var body: some View {
        let videos = model.base.filter(\.isVideo)
        let photos = model.base.filter { !$0.isVideo }
        let videoBytes = videos.reduce(0) { $0 + $1.bytes }
        let photoBytes = photos.reduce(0) { $0 + $1.bytes }
        let total = max(videoBytes + photoBytes, 1)
        VStack(alignment: .leading, spacing: 18) {
            CardTitle(title: "Space on the drive", symbol: "chart.bar.xaxis")
            VStack(alignment: .leading, spacing: 2) {
                Text((videoBytes + photoBytes).bytes)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("for what's on \(model.device.name) now").font(.callout).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let gap: CGFloat = 2
                let width = max(geo.size.width - gap, 0)
                HStack(spacing: gap) {
                    UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4)
                        .fill(Color.chartVideos)
                        .frame(width: width * CGFloat(Double(videoBytes) / Double(total)))
                    UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                        .fill(Color.chartPhotos)
                }
            }
            .frame(height: 14)
            .accessibilityElement()
            .accessibilityLabel("Videos \(videoBytes.bytes), photos \(photoBytes.bytes)")
            HStack(alignment: .top, spacing: 28) {
                LegendValue(color: .chartVideos, title: "Videos", value: videoBytes.bytes,
                            detail: "\(videos.count.formatted()) · \(share(videoBytes, of: total))")
                LegendValue(color: .chartPhotos, title: "Photos", value: photoBytes.bytes,
                            detail: "\(photos.count.formatted()) · \(share(photoBytes, of: total))")
            }
        }
        .modernCard()
    }

    private func share(_ part: UInt64, of total: UInt64) -> String {
        (Double(part) / Double(total)).formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct LegendValue: View {
    let color: Color
    let title: String
    let value: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).foregroundStyle(.secondary)
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                Text(detail).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Years

/// Items taken each year, one bar per year. Hover a bar for its count.
private struct YearsCard: View {
    let model: PhoneLibraryModel
    @State private var hovered: String?

    private struct Year: Identifiable {
        var label: String
        var count: Int
        var id: String { label }
    }

    var body: some View {
        let years = Cleanup.byYear(model.base).compactMap { year in
            year.year.map { Year(label: String($0), count: year.assets.count) }
        }
        let busiest = years.max { $0.count < $1.count }
        VStack(alignment: .leading, spacing: 18) {
            CardTitle(title: "Over the years", symbol: "calendar")
            VStack(alignment: .leading, spacing: 2) {
                if let hovered, let year = years.first(where: { $0.label == hovered }) {
                    Text(year.count.formatted()).font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("taken in \(year.label)").font(.callout).foregroundStyle(.secondary)
                } else if let busiest {
                    Text(busiest.label).font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("the busiest year, with \(busiest.count.formatted())").font(.callout).foregroundStyle(.secondary)
                }
            }
            Chart(years) { year in
                BarMark(x: .value("Year", year.label), y: .value("Items", year.count))
                    .foregroundStyle(hovered == nil || hovered == year.label ? Color.imago : Color.imago.opacity(0.35))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
            }
            .chartXSelection(value: $hovered)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel().foregroundStyle(.secondary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisValueLabel().foregroundStyle(.secondary)
                }
            }
            .frame(height: 120)
        }
        .modernCard()
    }
}

// MARK: - Free up space

private struct FreeUpSpaceCard: View {
    let model: PhoneLibraryModel
    let device: PairedDevice
    let open: (PhoneSection?) -> Void

    var body: some View {
        let backedUp = model.assets.filter(\.isBackedUp)
        let screenshots = model.assets(of: .screenshots) + model.assets(of: .screenRecordings)
        VStack(alignment: .leading, spacing: 18) {
            CardTitle(title: "Free up space on the iPhone", symbol: "sparkles")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(backedUp.reduce(0) { $0 + $1.bytes }.bytes)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("is backed up, so it's safe to remove from \(device.name)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ActionTile(title: "Large Videos", symbol: "film.stack",
                           value: model.largeVideos.reduce(0) { $0 + $1.bytes }.bytes,
                           detail: count(model.largeVideos.count, "video")) { open(.largeVideos) }
                ActionTile(title: "Duplicates", symbol: "plus.square.on.square",
                           value: model.duplicates.reduce(0) { $0 + $1.reclaimableBytes }.bytes,
                           detail: count(model.duplicates.count, "set")) { open(.duplicates) }
                ActionTile(title: "Screenshots", symbol: "camera.viewfinder",
                           value: screenshots.reduce(0) { $0 + $1.bytes }.bytes,
                           detail: count(screenshots.count, "item")) { open(.mediaType(.screenshots)) }
                if !model.deleting.isEmpty {
                    ActionTile(title: "Waiting to Delete", symbol: "trash",
                               value: model.deleting.reduce(0) { $0 + $1.bytes }.bytes,
                               detail: count(model.deleting.count, "item")) { open(.deleting) }
                }
            }
        }
        .modernCard()
    }

    private func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n.formatted()) \(noun)s"
    }
}

/// A place to free space, opening it on the Photos page.
private struct ActionTile: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol).font(.title3).foregroundStyle(Color.imago)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout).foregroundStyle(.secondary)
                    Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                    Text(detail).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hovering ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Open in Photos")
    }
}

// MARK: - Contents

/// What kinds of photos and videos are on it, each opening its Media Type on the Photos page.
private struct ContentsCard: View {
    let model: PhoneLibraryModel
    let open: (PhoneSection?) -> Void

    var body: some View {
        let dates = model.base.compactMap(\.metadata.creationDate)
        let types = PhoneMediaType.allCases.filter { model.mediaTypeCounts[$0, default: 0] > 0 }
        VStack(alignment: .leading, spacing: 16) {
            CardTitle(title: "What's on it", symbol: "photo.on.rectangle.angled") {
                if let oldest = dates.min(), let newest = dates.max() {
                    Text("\(oldest.formatted(.dateTime.month(.abbreviated).year())) – \(newest.formatted(.dateTime.month(.abbreviated).year()))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            FlowLayout(spacing: 8) {
                Chip(title: "Favorites", symbol: "heart.fill", count: model.favorites.count) { open(.favorites) }
                ForEach(types) { type in
                    Chip(title: type.title, symbol: type.symbol, count: model.mediaTypeCounts[type, default: 0]) { open(.mediaType(type)) }
                }
            }
        }
        .modernCard()
    }
}

private struct Chip: View {
    let title: String
    let symbol: String
    let count: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(Color.imago)
                Text(title)
                Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.primary.opacity(hovering ? 0.08 : 0.045), in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Lays children out in rows, wrapping to the next row when one is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: - Changes

private struct ChangesCard: View {
    let model: PhoneLibraryModel
    let device: PairedDevice
    let openQueue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "Changes for the iPhone", symbol: "iphone.and.arrow.forward") {
                Button("See All", action: openQueue).buttonStyle(.link)
            }
            if !model.queue.pending.isEmpty {
                Text(model.queue.pending.count == 1 ? "1 change waiting for \(device.name)" : "\(model.queue.pending.count) changes waiting for \(device.name)")
                    .font(.callout.weight(.medium))
            }
            ForEach(model.queue.done.prefix(4)) { done in
                HStack(spacing: 10) {
                    Image(systemName: done.report.outcome == .applied ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(done.report.outcome == .applied ? .green : .secondary)
                    Text(done.change.summary)
                    Spacer()
                    Text(done.report.date.shortRelative).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .modernCard()
    }
}
