import AppKit
import ImagoKit
import SwiftUI
import UniformTypeIdentifiers

// Pieces shared by the grids: the backup Library and Folders, and the iPhone's Photos.

/// Something a grid can lay out by the day it was taken.
protocol Dated: Identifiable where ID == String {
    var date: Date? { get }
    var isVideo: Bool { get }
}

extension MediaItem: Dated {}

extension PhoneAsset: Dated {
    var date: Date? { metadata.creationDate }
}

// MARK: - Days

struct Day<Item: Dated>: Identifiable {
    var date: Date?
    var items: [Item]
    var id: Date { date ?? .distantPast }

    /// Items grouped by the day they were taken, in the order given; items without a date last.
    static func group(_ items: [Item]) -> [Day] {
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

    var summary: String {
        let videos = items.count { $0.isVideo }
        let photos = items.count - videos
        return [photos > 0 ? "\(photos) \(photos == 1 ? "photo" : "photos")" : nil,
                videos > 0 ? "\(videos) \(videos == 1 ? "video" : "videos")" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

struct DayHeader<Item: Dated>: View {
    let day: Day<Item>
    var selectAll: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(day.title).font(.title3.weight(.semibold))
            Text(day.summary).font(.callout).foregroundStyle(.secondary)
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
}

// MARK: - Selection

/// Click selection as in Finder and Photos: a click selects, ⌘-click toggles, ⇧-click selects a range.
struct GridSelection {
    var selected: Set<String> = []
    /// Where a ⇧-click range starts.
    var anchor: String?

    enum Click { case selected, doubleClicked }

    /// Applies the current mouse event's click to `id`. Returns `.doubleClicked` for a second click on the same item.
    mutating func click(_ id: String, in ids: [String]) -> Click {
        let event = NSApp.currentEvent
        // Two quick clicks on different items are two clicks, not a double-click.
        if event?.clickCount == 2, anchor == id { return .doubleClicked }
        let modifiers = event?.modifierFlags ?? []
        if modifiers.contains(.shift), let anchor,
           let from = ids.firstIndex(of: anchor), let to = ids.firstIndex(of: id) {
            selected.formUnion(ids[min(from, to)...max(from, to)])
        } else if modifiers.contains(.command) {
            selected.formSymmetricDifference([id])
            anchor = id
        } else {
            selected = [id]
            anchor = id
        }
        return .selected
    }
}

// MARK: - Keys

/// A grid's shortcuts, as in Finder: Space, ⌘O, Escape, ⌘A (select all), ⌥⌘A (deselect all), and
/// Delete or ⌘⌫, plus any extra keys it wants. While the grid has the keyboard, Edit › Deselect All
/// and the delete command act on it too (see `GridCommands`).
struct GridKeys: ViewModifier {
    var focused: FocusState<Bool>.Binding
    var clear: () -> Void
    var selectAll: () -> Void
    var preview: () -> Void
    var open: () -> Void
    var delete: () -> Void
    /// For Edit › Delete: "Move to Recently Deleted", "Delete from iPhone…"…
    var deleteTitle = "Move to Recently Deleted"
    /// Edit › Copy (⌘C): the selected files, to paste in Finder.
    var copy: (() -> [URL])? = nil
    /// Edit › Paste (⌘V): files from Finder, or copied here; nil where nothing can be pasted.
    var paste: (([URL]) -> Void)? = nil
    /// Other characters, e.g. "." to favorite.
    var extra: [Character: () -> Void] = [:]

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { clear() }
            .focusable()
            .focused(focused)
            .focusEffectDisabled()
            .focusedValue(\.gridCommands, GridCommandActions(deselectAll: clear, delete: delete, deleteTitle: deleteTitle))
            .onCopyCommand { (copy?() ?? []).map { NSItemProvider(object: $0 as NSURL) } }
            .onPasteCommand(of: paste == nil ? [] : [.fileURL]) { providers in
                Task { if let paste { paste(await Self.fileURLs(from: providers)) } }
            }
            .onAppear { focused.wrappedValue = true }
            .onKeyPress(.space) { preview(); return .handled }
            .onKeyPress(characters: ["o", "\u{F701}"]) { press in   // ⌘O and ⌘↓, as in Finder
                guard press.modifiers.contains(.command) else { return .ignored }
                open()
                return .handled
            }
            .onKeyPress(.escape) { clear(); return .handled }
            .onKeyPress(characters: ["a"]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                // ⌥⌘A deselects, as in Finder; ⌘A selects everything.
                if press.modifiers.contains(.option) { clear() } else { selectAll() }
                return .handled
            }
            // Delete or ⌘⌫. The Delete key arrives as DEL (0x7F) on the Mac, forward delete as 0xF728.
            .onKeyPress(characters: ["\u{7F}", "\u{08}", "\u{F728}"]) { press in
                guard press.modifiers.isSubset(of: [.command]) else { return .ignored }
                delete()
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: String(extra.keys))) { press in
                guard press.modifiers.isEmpty || press.modifiers == .shift, let action = press.characters.first.flatMap({ extra[$0] }) else { return .ignored }
                action()
                return .handled
            }
    }

    /// The file URLs on the pasteboard (or in a drop).
    static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { done in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    done.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                }
            }
            if let url { urls.append(url) }
        }
        return urls
    }
}

// MARK: - Selection box

/// Where each tile is in its grid, for the selection box. A plain class: tiles write it as they're laid
/// out, and nothing redraws for it.
final class TileFrames {
    var frames: [String: CGRect] = [:]
    /// Day headers on screen. Pinned ones sit over tiles: a drag starting on one draws a box.
    var headers: [String: CGRect] = [:]
}

extension View {
    /// Records this tile's frame in its grid, for the selection box.
    func tileFrame(_ id: String, in frames: TileFrames) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SelectionBox.space)) } action: { frames.frames[id] = $0 }
    }

    /// Records a day header's frame while it's on screen, for the selection box.
    func headerFrame(_ id: String, in frames: TileFrames) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SelectionBox.space)) } action: { frames.headers[id] = $0 }
            .onDisappear { frames.headers[id] = nil }
    }
}

/// Drag from anywhere that isn't a tile (gaps, margins, day headers, below the last row) to select
/// the tiles the box touches, as in Finder. With ⌘ or ⇧ held, they're added to the selection instead
/// of replacing it. Past the top or bottom edge, the grid scrolls, faster the further out the pointer is.
///
/// Apply it to the scroll view's whole content, so the box's coordinates are the content's.
struct SelectionBox: ViewModifier {
    static let space = "selectionBox"
    let frames: TileFrames
    /// The tiles' IDs, so only ones still in the grid are picked. Asked for when a box starts.
    let ids: () -> Set<String>
    @Binding var selection: Set<String>
    @State private var box: CGRect?
    @State private var drag = BoxDrag()

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .coordinateSpace(.named(Self.space))
            // Alongside the tiles' own clicks and drags: a drag that starts on a tile is theirs.
            .simultaneousGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                    .onChanged { value in changed(start: value.startLocation, location: value.location) }
                    .onEnded { _ in ended() }
            )
            .overlay(alignment: .topLeading) {
                if let box {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
                        .frame(width: box.width, height: box.height)
                        .offset(x: box.minX, y: box.minY)
                        .allowsHitTesting(false)
                }
            }
    }

    private func changed(start: CGPoint, location: CGPoint) {
        // A new press. The last one may never have ended: a tile's drag takes the mouse, and the
        // gesture doesn't hear its release.
        if drag.phase != .idle, start != drag.start {
            drag.autoscroll?.cancel()
            drag = BoxDrag()
        }
        switch drag.phase {
        case .ignoring:
            return
        case .idle:
            let ids = ids()
            // On a tile (and not a day header pinned over it): it's dragging the tile, not drawing a box.
            if !frames.headers.values.contains(where: { $0.contains(start) }),
               frames.frames.contains(where: { $0.value.contains(start) && ids.contains($0.key) }) {
                drag.phase = .ignoring
                drag.start = start
                return
            }
            drag.ids = ids
            let modifiers = NSEvent.modifierFlags
            drag.before = modifiers.contains(.command) || modifiers.contains(.shift) ? selection : []
            drag.start = start
            drag.scrollView = Self.scrollView(under: NSEvent.mouseLocation)
            drag.phase = .boxing
            startAutoscroll()
        case .boxing:
            break
        }
        drag.location = location
        drag.originAtLocation = drag.scrollView?.contentView.bounds.origin.y ?? 0
        update()
    }

    private func ended() {
        drag.autoscroll?.cancel()
        drag = BoxDrag()
        box = nil
    }

    /// Redraws the box to the pointer and selects what it touches. Writes the selection only when
    /// it changes: every write redraws the grid.
    private func update() {
        let rect = CGRect(x: min(drag.start.x, drag.location.x), y: min(drag.start.y, drag.location.y),
                          width: abs(drag.location.x - drag.start.x), height: abs(drag.location.y - drag.start.y))
        box = rect
        var inside = drag.before
        for (id, frame) in frames.frames where frame.intersects(rect) && drag.ids.contains(id) { inside.insert(id) }
        if inside != selection { selection = inside }
    }

    /// While the box is drawn: with the pointer past the top or bottom of the grid, scroll, and grow
    /// the box with the content.
    private func startAutoscroll() {
        drag.autoscroll = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard drag.phase == .boxing, let scrollView = drag.scrollView else { continue }
                let clip = scrollView.contentView
                guard clip.isFlipped, let window = scrollView.window else { continue }
                let pointer = clip.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                let visible = clip.bounds
                let top = visible.minY + scrollView.contentInsets.top, bottom = visible.maxY - scrollView.contentInsets.bottom
                let margin: CGFloat = 20
                let overshoot = pointer.y < top + margin ? pointer.y - (top + margin)
                    : pointer.y > bottom - margin ? pointer.y - (bottom - margin) : 0
                guard overshoot != 0 else { continue }
                // Faster the further out, as in Finder.
                let step = (overshoot.sign == .minus ? -1 : 1) * min(4 + abs(overshoot) * 0.35, 60)
                var target = visible
                target.origin.y += step
                target = clip.constrainBoundsRect(target)
                let moved = target.origin.y - visible.origin.y
                guard moved != 0 else { continue }
                clip.scroll(to: target.origin)
                scrollView.reflectScrolledClipView(clip)
                // The pointer hasn't moved on screen, so in the content it moved with the scroll.
                drag.location.y += target.origin.y - drag.originAtLocation
                drag.originAtLocation = target.origin.y
                update()
            }
        }
    }

    /// The scroll view under a point on screen: the grid's, when the drag starts.
    private static func scrollView(under screenPoint: NSPoint) -> NSScrollView? {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.contains(screenPoint) }),
              let contentView = window.contentView else { return nil }
        let point = contentView.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return contentView.hitTest(point)?.enclosingScrollView
    }
}

/// One box being drawn. A class, so the autoscroll loop and the gesture share it without redrawing.
private final class BoxDrag {
    enum Phase { case idle, boxing, ignoring }
    var phase = Phase.idle
    var start: CGPoint = .zero
    var location: CGPoint = .zero
    /// The scroll position when `location` was last set from the pointer.
    var originAtLocation: CGFloat = 0
    var before: Set<String> = []
    var ids: Set<String> = []
    weak var scrollView: NSScrollView?
    var autoscroll: Task<Void, Never>?
}

/// Makes a scroll view's content at least as tall as the scroll view, so a box can start below the
/// last row of a short grid.
struct FillsViewport: ViewModifier {
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: height, alignment: .top)
            .background {
                // The scroll view's own height, not the content's.
                Color.clear.containerRelativeFrame(.vertical)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
    }
}

// MARK: - Open With

/// Right-click › Open With: the apps that can open these files, the default first, and Other….
struct OpenWithMenu: View {
    let urls: [URL]

    var body: some View {
        Menu("Open With") {
            if let first = urls.first {
                let apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
                let preferred = NSWorkspace.shared.urlForApplication(toOpen: first)
                ForEach(apps, id: \.self) { app in
                    Button { open(with: app) } label: {
                        Label {
                            Text(name(of: app) + (app == preferred ? " (default)" : ""))
                        } icon: {
                            Image(nsImage: icon(of: app))
                        }
                    }
                }
                if !apps.isEmpty { Divider() }
                Button("Other…") { chooseApp() }
            }
        }
    }

    private func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    private func icon(of app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private func open(with app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.message = "Choose an app to open \(urls.count == 1 ? "this file" : "these files")."
        guard panel.runModal() == .OK, let app = panel.url else { return }
        open(with: app)
    }
}

/// What Edit › Deselect All and the delete command do to the grid with the keyboard.
struct GridCommandActions {
    var deselectAll: () -> Void
    var delete: () -> Void
    var deleteTitle: String
}

extension FocusedValues {
    @Entry var gridCommands: GridCommandActions?
}

/// Edit › Deselect All (⌥⌘A) and the delete command (⌘⌫), for the grid with the keyboard. Disabled
/// otherwise, so in a text field ⌘⌫ still deletes text.
struct GridCommands: Commands {
    @FocusedValue(\.gridCommands) private var grid

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Deselect All") { grid?.deselectAll() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(grid == nil)
            Button(grid?.deleteTitle ?? "Move to Recently Deleted") { grid?.delete() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(grid == nil)
        }
    }
}

// MARK: - Selection bar

/// The floating bar at the bottom of a grid with a selection: a count and size, then actions.
struct FloatingBar<Actions: View>: View {
    let count: Int
    let detail: String
    var clear: () -> Void
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(count == 1 ? "1 item" : "\(count.formatted()) items").font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 70, alignment: .leading)

            Divider().frame(height: 26)

            actions

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

/// A selected tile's ring in the accent color, as in Photos: no checkmark, no tint over the photo.
/// A thin light line inside keeps it clear against dark photos.
struct SelectedOverlay: ViewModifier {
    let selected: Bool
    var cornerRadius: CGFloat = 6

    func body(content: Content) -> some View {
        content
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.tint, lineWidth: 3.5)
                        .overlay(
                            RoundedRectangle(cornerRadius: max(cornerRadius - 3.5, 0), style: .continuous)
                                .strokeBorder(.white.opacity(0.85), lineWidth: 1)
                                .padding(3.5)
                        )
                        .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.12), value: selected)
    }
}

/// Pinch on the trackpad to make thumbnails bigger or smaller, as in Photos.
struct PinchToResize: ViewModifier {
    @Binding var size: Double
    var range: ClosedRange<Double> = 90...300
    @State private var start: Double?

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = start ?? size
                    if start == nil { start = size }
                    let new = min(max(base * value.magnification, range.lowerBound), range.upperBound)
                    // Whole points only: every change lays the grid out again.
                    if abs(new - size) >= 1 { size = new.rounded() }
                }
                .onEnded { _ in start = nil }
        )
    }
}

/// The thumbnail size slider in a grid's toolbar.
struct TileSizeSlider: View {
    @Binding var size: Double

    var body: some View {
        HStack(spacing: 6) {
            Slider(value: $size, in: 90...300).frame(width: 96).controlSize(.small)
                .padding(.leading, 4)
            Image(systemName: "photo").imageScale(.large).foregroundStyle(.secondary)
        }
        .help("Thumbnail size")
    }
}

// MARK: - Show

/// All | Photos | Videos, in a page's toolbar.
struct KindPicker: View {
    @Binding var selection: MediaLibrary.Kind

    var body: some View {
        Picker("Show", selection: $selection) {
            Label("All", systemImage: "square.grid.2x2").tag(MediaLibrary.Kind.all)
            Label("Photos", systemImage: "photo").tag(MediaLibrary.Kind.photos)
            Label("Videos", systemImage: "video").tag(MediaLibrary.Kind.videos)
        }
        .pickerStyle(.segmented)
        .labelStyle(.titleOnly)
        .help("Show photos, videos or both")
    }
}

extension MediaLibrary.Kind {
    /// Whether something that is (or isn't) a video belongs.
    func includes(isVideo: Bool) -> Bool {
        switch self {
        case .all: true
        case .photos: !isVideo
        case .videos: isVideo
        }
    }
}

/// What a library view shows: on all iPhones (the default), on one, or everything on the backup drive.
struct SourcePicker: View {
    @Environment(BackupServer.self) private var server
    @Binding var selection: String
    var everything = "Everything on the Drive"

    var body: some View {
        Picker("Show", selection: $selection) {
            Text("On All iPhones").tag(MediaLibrary.Source.phones.raw)
            ForEach(server.devices) { device in
                Text("On \(device.name)").tag(MediaLibrary.Source.phone(device.id).raw)
            }
            Divider()
            Text(everything).tag(MediaLibrary.Source.drive.raw)
        }
        .fixedSize()
        .help("Show what's on your iPhones (as of their last backup), on one of them, or everything on the backup drive")
    }
}
