import AppKit
import AreteMedia
import CoreLocation
import SwiftUI

/// The in-app viewer (AreteMedia's `MediaViewer`, embedded). A photo or video opened from any grid
/// shows over the window's content, like the Photos app: it grows out of its thumbnail, the toolbar
/// turns into the viewer's (back, when it was taken, info, share, favorite), and the background
/// follows the appearance. It opens at once on the grid's thumbnail and sharpens when the full
/// photo is decoded. Closing shrinks it back into its thumbnail.
@MainActor @Observable
final class MediaViewerHost {
    /// The coordinate space grids report a thumbnail's frame in: the window's content area, which
    /// the viewer covers.
    static let space = "mediaViewer"

    struct InfoRow: Identifiable {
        var label: String
        var value: String
        var id: String { label }
    }

    /// The files to step through, and what the toolbar and info panel show about each.
    struct Request: Identifiable {
        let id = UUID()
        var urls: [URL]
        var index: Int
        /// What each file's grid thumbnail is keyed by, to show it while the full photo loads.
        var thumbnailBytes: [URL: UInt64]
        /// When it was taken: the toolbar's title, as in Photos.
        var date: (Int) -> Date?
        /// Shown instead when there's no date.
        var name: (Int) -> String
        /// Where it was taken, named over the date in the toolbar's title; nil when not known.
        var coordinate: (Int) -> CLLocationCoordinate2D? = { _ in nil }
        var info: (Int) -> [InfoRow]
        /// Whether it's a favorite on the iPhone; nil where favorites don't apply.
        var isFavorite: ((Int) -> Bool)? = nil
        var toggleFavorite: ((Int) -> Void)? = nil
        /// Where the opened item's thumbnail is, in `space`: the viewer grows out of it and shrinks
        /// back into it. Nil to fade instead.
        var sourceFrame: CGRect? = nil
        /// Files an edited copy of the item at this index (a new file; the original is never changed).
        /// Returns where it went ("Tennis"), or nil when it couldn't. Nil where editing doesn't apply.
        var saveEdit: ((Int, URL) async -> String?)? = nil
        /// Whether the item at this index can be edited: not a preview of one that isn't backed up yet.
        var canEdit: (Int) -> Bool = { _ in true }
        /// The delete button's help, e.g. "Move to Recently Deleted"; nil where there's nothing to delete.
        var deleteTitle: String? = nil
        /// Deletes the item at this index. Returns whether it went, so the viewer moves to the next one.
        var delete: ((Int) async -> Bool)? = nil
    }

    private(set) var request: Request?
    /// The item on screen, as an index into `request.urls`.
    var index = 0
    /// Items deleted while the viewer is open: no longer stepped through.
    private(set) var removed = IndexSet()
    /// Changes when the viewer must start again on another item (after a deletion).
    private(set) var viewerRevision = 0

    /// Indexes into `request.urls` still shown, in order.
    var shown: [Int] {
        guard let request else { return [] }
        return request.urls.indices.filter { !removed.contains($0) }
    }

    /// Where the item on screen is among those still shown.
    var position: Int { shown.firstIndex(of: index) ?? 0 }
    var showingInfo = false
    /// The item on screen is open in the editor.
    var editing = false
    /// Said briefly over the viewer, e.g. where an edited copy went.
    private(set) var notice: String?
    /// Closing: the viewer is shrinking back into its thumbnail.
    private(set) var isClosing = false

    var isOpen: Bool { request != nil }

    /// Opens `request.urls[request.index]`; ← and → move through the rest.
    func open(_ request: Request) {
        guard request.urls.indices.contains(request.index) else { return }
        isClosing = false
        editing = false
        self.request = request
        index = request.index
        removed = []
        // A video plays from the backup drive: thumbnails made after backups can wait.
        Task { await Thumbnails.shared.holdBackgroundWork(true) }
    }

    /// Starts closing; the overlay animates, then calls `finishClosing()`.
    func close() {
        guard request != nil else { return }
        isClosing = true
    }

    func finishClosing() {
        request = nil
        editing = false
        isClosing = false
        Task { await Thumbnails.shared.holdBackgroundWork(false) }
    }

    /// Deletes the item on screen, then shows the next one (or the one before, at the end); closes when
    /// none are left.
    func deleteCurrent() async {
        guard let request, let delete = request.delete else { return }
        let deleting = index
        guard await delete(deleting) else { return }
        let before = shown
        guard let at = before.firstIndex(of: deleting) else { return }
        removed.insert(deleting)
        let after = shown
        guard !after.isEmpty else {
            finishClosing()
            return
        }
        index = after[min(at, after.count - 1)]
        viewerRevision += 1
    }

    /// Files the editor's copy of the item on screen, then leaves the editor and says where it went.
    func saveEdit(_ copy: URL) async -> Bool {
        guard let save = request?.saveEdit, let place = await save(index, copy) else { return false }
        editing = false
        show("Saved a copy to “\(place)”")
        return true
    }

    private func show(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notice == text { notice = nil }
        }
    }

    /// The thumbnail to show for a file while it opens or closes.
    func thumbnail(_ url: URL) -> CGImage? {
        Thumbnails.shared.stored(url, bytes: request?.thumbnailBytes[url] ?? 0)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

extension View {
    /// Shows the viewer over this view while one is open, with its toolbar. Grids inside report the
    /// opened thumbnail's frame in `MediaViewerHost.space`, which this sets up.
    func mediaViewerOverlay() -> some View {
        modifier(MediaViewerOverlay())
    }

    /// Reports this view's frame in the viewer's space while `active` (e.g. the item a double-click
    /// would open), so the viewer can grow out of it.
    func reportsViewerSourceFrame(_ active: Bool, to frame: Binding<CGRect?>) -> some View {
        modifier(SourceFrameReporter(active: active, frame: frame))
    }
}

private struct SourceFrameReporter: ViewModifier {
    let active: Bool
    @Binding var frame: CGRect?

    func body(content: Content) -> some View {
        if active {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MediaViewerHost.space)) } action: { frame = $0 }
        } else {
            content
        }
    }
}

private struct MediaViewerOverlay: ViewModifier {
    @Environment(MediaViewerHost.self) private var host

    /// The thumbnail flying between its tile and the viewer.
    struct Flight {
        var image: CGImage
        var frame: CGRect
        var cornerRadius: CGFloat
    }

    @State private var flight: Flight?
    /// The real viewer is showing (it's hidden during the flight).
    @State private var showingViewer = false
    @State private var backdrop: Double = 0

    private static let grow = Animation.spring(duration: 0.34, bounce: 0.1)
    private static let shrink = Animation.spring(duration: 0.28, bounce: 0)

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(MediaViewerHost.space))
            .overlay {
                if let request = host.request {
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            Color.mediaBackground.opacity(backdrop)
                            // There from the start, so a video starts loading during the flight;
                            // seen once the thumbnail lands where the viewer shows it.
                            viewer(request)
                                .opacity(showingViewer ? 1 : 0)
                                .allowsHitTesting(showingViewer)
                            if let flight {
                                Image(decorative: flight.image, scale: 1)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: flight.frame.width, height: flight.frame.height)
                                    .clipShape(RoundedRectangle(cornerRadius: flight.cornerRadius, style: .continuous))
                                    .offset(x: flight.frame.minX, y: flight.frame.minY)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onAppear { open(request, in: geo.size) }
                        .onChange(of: request.id) { open(request, in: geo.size) }
                        .onChange(of: host.isClosing) { _, closing in if closing { close(request, in: geo.size) } }
                    }
                }
            }
            .toolbar {
                // The editor has its own Cancel and Save as Copy.
                if let request = host.request, !host.isClosing, !host.editing {
                    ViewerToolbar(request: request, host: host)
                }
            }
    }

    @ViewBuilder
    private func viewer(_ request: MediaViewerHost.Request) -> some View {
        if host.editing, request.urls.indices.contains(host.index) {
            // The editor takes the viewer's place, as in Photos; it saves a new file only.
            MediaEditView(url: request.urls[host.index], accent: .imago,
                          onCancel: { host.editing = false },
                          onSave: { await host.saveEdit($0) })
                .id(request.urls[host.index])
                .transition(.opacity)
        } else {
            browsing(request)
                .overlay(alignment: .bottom) {
                    if let notice = host.notice {
                        Text(notice)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 24)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: host.notice)
        }
    }

    private func browsing(_ request: MediaViewerHost.Request) -> some View {
        HStack(spacing: 0) {
            let shown = host.shown
            MediaViewer(
                urls: shown.map { request.urls[$0] }, startAt: host.position, accent: .imago,
                placeholder: { host.thumbnail($0) },
                embedded: true,
                onIndexChange: { position in if shown.indices.contains(position) { host.index = shown[position] } },
                slowStartMessage: "Waking up the backup drive…",
                onClose: { host.close() }
            )
            .id("\(request.id)-\(host.viewerRevision)")
            // Delete (and ⌘⌫, in the toolbar) deletes what's on screen.
            .onKeyPress(characters: ["\u{7F}", "\u{08}", "\u{F728}"]) { press in
                guard request.delete != nil, press.modifiers.isEmpty else { return .ignored }
                Task { await host.deleteCurrent() }
                return .handled
            }
            if host.showingInfo {
                Divider()
                InfoPanel(rows: request.info(host.index))
                    .frame(width: 280)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: host.showingInfo)
    }

    /// Grows the thumbnail from its tile to where the viewer shows it, then hands over to the viewer,
    /// which starts on the same image in the same place.
    private func open(_ request: MediaViewerHost.Request, in size: CGSize) {
        let url = request.urls[request.index]
        guard let source = request.sourceFrame, let image = host.thumbnail(url) else {
            flight = nil
            showingViewer = true
            withAnimation(.easeOut(duration: 0.15)) { backdrop = 1 }
            return
        }
        showingViewer = false
        backdrop = 0
        flight = Flight(image: image, frame: source, cornerRadius: 6)
        let target = fitted(image, in: CGRect(origin: .zero, size: size))
        withAnimation(Self.grow) {
            flight?.frame = target
            flight?.cornerRadius = 0
            backdrop = 1
        } completion: {
            showingViewer = true
            flight = nil
        }
    }

    /// Shrinks the item on screen back into its tile when it's the one that was opened (the grid
    /// hasn't moved under the viewer); fades otherwise.
    private func close(_ request: MediaViewerHost.Request, in size: CGSize) {
        let url = request.urls.indices.contains(host.index) ? request.urls[host.index] : nil
        let width = size.width - (host.showingInfo ? 281 : 0)
        guard host.index == request.index, let source = request.sourceFrame,
              let url, let image = host.thumbnail(url) else {
            withAnimation(.easeOut(duration: 0.15)) {
                showingViewer = false
                backdrop = 0
            } completion: { host.finishClosing() }
            return
        }
        flight = Flight(image: image, frame: fitted(image, in: CGRect(x: 0, y: 0, width: width, height: size.height)), cornerRadius: 0)
        showingViewer = false
        withAnimation(Self.shrink) {
            flight?.frame = source
            flight?.cornerRadius = 6
            backdrop = 0
        } completion: {
            flight = nil
            host.finishClosing()
        }
    }

    /// Where an image of this shape sits when fitted into `box`, as the viewer shows it.
    private func fitted(_ image: CGImage, in box: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
    }
}

/// The toolbar while the viewer is open, laid out like Photos'.
private struct ViewerToolbar: ToolbarContent {
    let request: MediaViewerHost.Request
    @Bindable var host: MediaViewerHost

    var body: some ToolbarContent {
        let index = host.index
        ToolbarItem(placement: .navigation) {
            Button { host.close() } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .help("Back to the grid (Esc)")
        }
        let title = ViewerTitle(date: request.date(index), name: request.name(index), coordinate: request.coordinate(index),
                                position: host.shown.count > 1 ? "\(host.position + 1) of \(host.shown.count.formatted())" : nil)
        // Two lines don't fit in a toolbar button's glass capsule: plain text over the bar, as in Photos.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) { title }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { title }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { host.showingInfo.toggle() } label: {
                Label("Info", systemImage: host.showingInfo ? "info.circle.fill" : "info.circle")
            }
            .help("Show details")
            if request.saveEdit != nil, request.canEdit(index) {
                Button { host.editing = true } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
                .keyboardShortcut("e", modifiers: .command)
                .help("Turn, flip, crop or trim a copy (⌘E). The original stays as it is.")
            }
            if request.urls.indices.contains(index) {
                ShareLink(item: request.urls[index]) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .help("Share")
            }
            if let isFavorite = request.isFavorite, let toggle = request.toggleFavorite {
                let favorite = isFavorite(index)
                Button { toggle(index) } label: {
                    Label(favorite ? "Unfavorite" : "Favorite", systemImage: favorite ? "heart.fill" : "heart")
                        .foregroundStyle(favorite ? Color.imago : Color.primary)
                }
                .help(favorite ? "Unfavorite on the iPhone" : "Favorite on the iPhone")
            }
            if let title = request.deleteTitle {
                Button { Task { await host.deleteCurrent() } } label: {
                    Label("Delete", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .help("\(title) (⌘⌫)")
            }
        }
    }
}

/// Details of the item on screen, beside it, like Photos' Info.
private struct InfoPanel: View {
    let rows: [MediaViewerHost.InfoRow]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Info").font(.title3.bold())
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label).font(.caption).foregroundStyle(.secondary)
                        Text(row.value).font(.callout).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The viewer's title, like Photos: where it was taken on top, when below in a smaller font
/// ("Yesterday  3:41 PM"). Without a place, the day on top and the time below. A long place gives way
/// to a shorter name for the area (see `PlaceNames`), then shrinks a little, and only then trails off;
/// the pointer shows the full place.
private struct ViewerTitle: View {
    let date: Date?
    let name: String
    let coordinate: CLLocationCoordinate2D?
    /// "3 of 120", in the tooltip.
    let position: String?

    @State private var place: PlaceNames.Place?

    var body: some View {
        VStack(spacing: 1) {
            Text(place?.short ?? date.map { Self.day($0) } ?? name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .truncationMode(.tail)
            if let date {
                Text(place == nil ? Self.time(date) : "\(Self.day(date))  \(Self.time(date))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 300)
        .help([place?.full, position].compactMap(\.self).joined(separator: "\n"))
        .task(id: coordinate.map { "\($0.latitude),\($0.longitude)" }) {
            place = nil
            guard let coordinate else { return }
            place = await PlaceNames.place(at: coordinate)
        }
    }

    /// Today, Yesterday, the weekday within the last week, otherwise the date.
    static func day(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? .max
        return (0..<7).contains(days) ? date.formatted(.dateTime.weekday(.wide)) : date.formatted(date: .long, time: .omitted)
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

/// Place names for coordinates, looked up once each (the geocoder is rate-limited) and kept while the
/// app runs. Nearby coordinates share an answer.
@MainActor
enum PlaceNames {
    struct Place: Sendable {
        /// For the title: short enough for one line, like Photos ("Golden Gate Park", "Nanshan").
        var short: String
        /// For the tooltip.
        var full: String
    }

    private static var cache: [String: Place?] = [:]

    static func place(at coordinate: CLLocationCoordinate2D) async -> Place? {
        // About 100 m.
        let key = String(format: "%.3f,%.3f", coordinate.latitude, coordinate.longitude)
        if let cached = cache[key] { return cached }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return nil  // Offline or rate-limited: try again next time.
        }
        let place = Self.place(placemark)
        cache[key] = place
        return place
    }

    /// A long point of interest gives way to the district or town; anything after a comma (a street,
    /// a region) is dropped.
    private static func place(_ p: CLPlacemark) -> Place? {
        let full = [p.areasOfInterest?.first, p.subLocality, p.locality, p.name].compactMap(\.self).first
        let candidates = [p.areasOfInterest?.first, p.subLocality, p.locality, p.name, p.administrativeArea]
            .compactMap { $0?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
        guard let short = candidates.first(where: { $0.count <= 28 }) ?? candidates.first else { return nil }
        // The full name with the town, when the title shows less: "Shenzhen Bay Sports Center, Nanshan, Shenzhen".
        let parts = [full, p.subLocality, p.locality].compactMap(\.self).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return Place(short: short, full: parts.joined(separator: ", "))
    }
}
