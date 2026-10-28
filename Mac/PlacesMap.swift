import ImagoKit
import MapKit
import SwiftUI

/// A photo or video with a place, for the map.
struct MapPin: Identifiable, Sendable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    /// What to show: the backed-up file (or the iPhone's preview).
    let thumbnail: URL?
    /// What its grid thumbnail is keyed by.
    let thumbnailBytes: UInt64
    let date: Date?
}

/// Places, like the Photos map on iOS: photos and videos where they were taken, grouped into one
/// bubble per area (its newest photo, and how many). Groups re-form as the map zooms. Click a group to
/// list its photos beside the map, to manage them there.
struct PlacesMap: View {
    let pins: [MapPin]
    /// Shows a group's items (by ID, newest first) beside the map.
    var select: ([String]) -> Void

    /// Fitted to the photos once, when the map opens; after that, where the user takes it. (Following
    /// `.automatic` would re-fit every time the groups change, and regrouping after each re-fit looped.)
    @State private var position: MapCameraPosition = .automatic
    @State private var fitted = false
    @State private var region: MKCoordinateRegion?
    /// Where the map looks from now, to keep the zoom when it moves to a group.
    @State private var camera: MapCamera?
    @State private var groups: [Group] = []

    struct Group: Identifiable {
        var id: String
        var coordinate: CLLocationCoordinate2D
        /// Newest first.
        var pins: [MapPin]
    }

    var body: some View {
        Map(position: $position) {
            ForEach(groups) { group in
                Annotation("", coordinate: group.coordinate, anchor: .center) {
                    Bubble(group: group)
                        .onTapGesture { tap(group) }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .mapControls {
            MapZoomStepper()
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            // Only a real move: regrouping changes the annotations, which mustn't feed back into here.
            guard !Self.same(region, context.region) else { return }
            region = context.region
            camera = context.camera
            regroup()
        }
        .onAppear {
            fitToPins()
            regroup()
        }
        .onChange(of: pins.count) { regroup() }
        .overlay {
            if pins.isEmpty {
                ContentUnavailableView("No places yet", systemImage: "map",
                                       description: Text("Photos and videos taken with Location Services on show here, where they were taken."))
                    .padding(30)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !pins.isEmpty {
                Text(pins.count == 1 ? "1 photo with a place" : "\(pins.count.formatted()) photos and videos with a place")
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(16)
            }
        }
    }

    /// Frames every photo, once.
    private func fitToPins() {
        guard !fitted, !pins.isEmpty else { return }
        fitted = true
        let lats = pins.map(\.coordinate.latitude), lons = pins.map(\.coordinate.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else { return }
        let fit = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: min(max((maxLat - minLat) * 1.3, 0.02), 170),
                                   longitudeDelta: min(max((maxLon - minLon) * 1.3, 0.02), 350))
        )
        region = fit
        position = .region(fit)
    }

    /// Whether two map regions are the same, near enough: a re-fit of the same view isn't a move.
    private static func same(_ a: MKCoordinateRegion?, _ b: MKCoordinateRegion) -> Bool {
        guard let a else { return false }
        let tolerance = max(b.span.latitudeDelta, b.span.longitudeDelta) * 0.01
        return abs(a.center.latitude - b.center.latitude) < tolerance && abs(a.center.longitude - b.center.longitude) < tolerance
            && abs(a.span.latitudeDelta - b.span.latitudeDelta) < tolerance && abs(a.span.longitudeDelta - b.span.longitudeDelta) < tolerance
    }

    /// Groups the pins into cells about a seventh of the visible map across.
    private func regroup() {
        let span = region?.span ?? MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 300)
        let latCell = max(span.latitudeDelta / 7, 0.000_5)
        let lonCell = max(span.longitudeDelta / 7, 0.000_5)
        var cells: [String: [MapPin]] = [:]
        for pin in pins {
            let key = "\(Int(floor(pin.coordinate.latitude / latCell)))|\(Int(floor(pin.coordinate.longitude / lonCell)))"
            cells[key, default: []].append(pin)
        }
        groups = cells.map { key, pins in
            let lat = pins.reduce(0) { $0 + $1.coordinate.latitude } / Double(pins.count)
            let lon = pins.reduce(0) { $0 + $1.coordinate.longitude } / Double(pins.count)
            return Group(id: key, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                         pins: pins.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) })
        }
    }

    /// Lists the group's photos beside the map, and centers the map on the group at the same zoom:
    /// the panel narrows the map, which would otherwise leave the group off to one side or under the
    /// edge. Zoom in with the trackpad or the zoom buttons to split the group.
    private func tap(_ group: Group) {
        select(group.pins.map(\.id))
        let target = camera.map { MapCamera(centerCoordinate: group.coordinate, distance: $0.distance, heading: $0.heading, pitch: $0.pitch) }
        withAnimation(.snappy(duration: 0.45)) {
            if let target {
                position = .camera(target)
            } else if let span = region?.span {
                position = .region(MKCoordinateRegion(center: group.coordinate, span: span))
            }
        }
    }
}

/// A group on the map: its newest photo, framed, with a count.
private struct Bubble: View {
    let group: PlacesMap.Group
    @State private var hovering = false

    var body: some View {
        let first = group.pins[0]
        ZStack {
            if let url = first.thumbnail {
                ThumbnailView(url: url, bytes: first.thumbnailBytes, cornerRadius: 9, showsName: false)
            } else {
                RoundedRectangle(cornerRadius: 9).fill(.quaternary)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white, lineWidth: 2.5))
        .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
        .overlay(alignment: .topTrailing) {
            if group.pins.count > 1 {
                Text(group.pins.count.formatted())
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.imago, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white, lineWidth: 1.5))
                    .offset(x: 8, y: -8)
            }
        }
        .scaleEffect(hovering ? 1.12 : 1)
        .animation(.snappy(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .help(group.pins.count == 1 ? "Open" : "\(group.pins.count) here")
    }
}

// MARK: - The whole library

/// Places for the library, by the Show menu (on the iPhones, or everything on the drive). A group's
/// photos open in a panel beside the map, as an ordinary grid: select, copy or move, delete, open.
struct LibraryPlacesView: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    @AppStorage(MediaLibrary.Source.key) private var sourceRaw = MediaLibrary.Source.phones.raw
    /// The group listed beside the map, by item ID.
    @State private var group: [String]?

    var body: some View {
        let located = library.filter(library.items, by: MediaLibrary.Source(raw: sourceRaw))
            .filter { $0.latitude != nil && $0.longitude != nil }
        HStack(spacing: 0) {
            PlacesMap(pins: located.map { item in
                MapPin(id: item.id, coordinate: CLLocationCoordinate2D(latitude: item.latitude!, longitude: item.longitude!),
                       thumbnail: item.url, thumbnailBytes: item.bytes, date: item.date)
            }) { group = $0 }
            if let group {
                PlacePanel(count: library.items(in: .items(group)).count, close: { self.group = nil }) {
                    BrowserView(scope: .items(group), embedded: true)
                }
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.snappy(duration: 0.25), value: group == nil)
        .navigationTitle("Places")
        .toolbar {
            ToolbarItem(placement: .principal) { SourcePicker(selection: $sourceRaw) }
        }
        .onChange(of: sourceRaw) { group = nil }
        .task(id: server.catalogRevision) { await library.load(from: server) }
    }
}

// MARK: - One iPhone

/// Places for one iPhone's library, including what isn't backed up yet (shown by its preview). A
/// group's photos open beside the map in the Photos grid, with all its actions.
struct PhonePlacesView: View {
    @Environment(BackupServer.self) private var server
    let model: PhoneLibraryModel
    let device: PairedDevice
    @State private var group: [String]?

    var body: some View {
        let previews = server.previews[device.id] ?? [:]
        let located = model.assets.filter { $0.metadata.location != nil }
        HStack(spacing: 0) {
            PlacesMap(pins: located.map { asset in
                MapPin(id: asset.id,
                       coordinate: CLLocationCoordinate2D(latitude: asset.metadata.location!.latitude, longitude: asset.metadata.location!.longitude),
                       thumbnail: model.files[asset.id] ?? previews[asset.id], thumbnailBytes: model.thumbnailBytes[asset.id] ?? 0,
                       date: asset.metadata.creationDate)
            }) { group = $0 }
            if let group {
                let assets = group.compactMap(model.asset)
                PlacePanel(count: assets.count, close: { self.group = nil }) {
                    PhoneGrid(model: model, device: device, assets: assets, empty: ("Nothing here", "map", nil))
                }
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.snappy(duration: 0.25), value: group == nil)
    }
}

/// Beside the map: how many photos are at the place, and their grid. Drag its left edge to resize it.
private struct PlacePanel<Content: View>: View {
    let count: Int
    let close: () -> Void
    @ViewBuilder var content: Content
    @AppStorage("placePanelWidth") private var width = 520.0
    /// The width when a resize began.
    @State private var startWidth: Double?

    var body: some View {
        HStack(spacing: 0) {
            Divider()
                .overlay {
                    // A wider strip than the line, to grab.
                    Color.clear
                        .frame(width: 9)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = startWidth ?? width
                                startWidth = start
                                width = min(max(start - drag.translation.width, 320), 1000)
                            }
                            .onEnded { _ in startWidth = nil })
                }
            panel
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack {
                Label(count == 1 ? "1 photo here" : "\(count.formatted()) photos here", systemImage: "mappin.and.ellipse")
                    .font(.headline)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            content
        }
        .frame(width: width)
    }
}
