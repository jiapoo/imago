import AppKit
import ImagoKit
import SwiftUI

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

/// Space, ⌘O, Escape, ⌘A and Delete for a grid, plus any extra keys it wants.
struct GridKeys: ViewModifier {
    var focused: FocusState<Bool>.Binding
    var clear: () -> Void
    var selectAll: () -> Void
    var preview: () -> Void
    var open: () -> Void
    var delete: () -> Void
    /// Other characters, e.g. "." to favorite.
    var extra: [Character: () -> Void] = [:]

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { clear() }
            .focusable()
            .focused(focused)
            .focusEffectDisabled()
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
                selectAll()
                return .handled
            }
            // The Delete key arrives as DEL (0x7F) on the Mac, forward delete as 0xF728.
            .onKeyPress(characters: ["\u{7F}", "\u{08}", "\u{F728}"]) { _ in delete(); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: String(extra.keys))) { press in
                guard press.modifiers.isEmpty || press.modifiers == .shift, let action = press.characters.first.flatMap({ extra[$0] }) else { return .ignored }
                action()
                return .handled
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
            Image(systemName: "photo").imageScale(.small).foregroundStyle(.secondary)
            Slider(value: $size, in: 90...300).frame(width: 96).controlSize(.small)
            Image(systemName: "photo").imageScale(.large).foregroundStyle(.secondary)
        }
        .help("Thumbnail size")
    }
}
