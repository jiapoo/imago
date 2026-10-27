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
/// zoom into it; once its photos are all at one spot, or for a single one, they open in the viewer.
struct PlacesMap: View {
    let pins: [MapPin]
    /// Opens these items (by ID) in the viewer, starting at the second.
    var open: ([String], String) -> Void

    /// Fitted to the photos once, when the map opens; after that, where the user takes it. (Following
    /// `.automatic` would re-fit every time the groups change, and regrouping after each re-fit looped.)
    @State private var position: MapCameraPosition = .automatic
    @State private var fitted = false
    @State private var region: MKCoordinateRegion?
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

    /// One photo, or photos all at one spot: open them. Otherwise zoom to where they are.
    private func tap(_ group: Group) {
        let lats = group.pins.map(\.coordinate.latitude), lons = group.pins.map(\.coordinate.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else { return }
        let spread = max(maxLat - minLat, maxLon - minLon)
        if group.pins.count == 1 || spread < 0.000_3 {
            open(group.pins.map(\.id), group.pins[0].id)
            return
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.6, 0.002), longitudeDelta: max((maxLon - minLon) * 1.6, 0.002))
        withAnimation(.smooth(duration: 0.5)) {
            position = .region(MKCoordinateRegion(center: center, span: span))
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

/// Places for every iPhone's backed-up photos and videos.
struct LibraryPlacesView: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    @Environment(FileHistory.self) private var history
    @Environment(MediaViewerHost.self) private var viewer

    var body: some View {
        let located = library.items.filter { $0.latitude != nil && $0.longitude != nil }
        PlacesMap(pins: located.map { item in
            MapPin(id: item.id, coordinate: CLLocationCoordinate2D(latitude: item.latitude!, longitude: item.longitude!),
                   thumbnail: item.url, thumbnailBytes: item.bytes, date: item.date)
        }) { ids, start in
            let byID = Dictionary(located.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let items = ids.compactMap { byID[$0] }
            guard let index = items.firstIndex(where: { $0.id == start }) else { return }
            viewer.open(.init(
                urls: items.map(\.url), index: index,
                thumbnailBytes: Dictionary(items.map { ($0.url, $0.bytes) }, uniquingKeysWith: { a, _ in a }),
                date: { items[$0].date },
                name: { items[$0].name },
                info: { [MediaViewerHost.InfoRow(label: "Name", value: items[$0].name), .init(label: "File", value: items[$0].url.path)] },
                deleteTitle: "Move to Recently Deleted",
                delete: { [library, server, history] index in
                    guard let step = await library.trash([items[index]], server: server) else { return false }
                    history.record(step)
                    return true
                }
            ))
        }
        .navigationTitle("Places")
        .task(id: server.catalogRevision) { await library.load(from: server) }
    }
}

// MARK: - One iPhone

/// Places for one iPhone's library, including what isn't backed up yet (shown by its preview).
struct PhonePlacesView: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaViewerHost.self) private var viewer
    let model: PhoneLibraryModel
    let device: PairedDevice

    var body: some View {
        let previews = server.previews[device.id] ?? [:]
        let located = model.assets.filter { $0.metadata.location != nil }
        PlacesMap(pins: located.map { asset in
            MapPin(id: asset.id,
                   coordinate: CLLocationCoordinate2D(latitude: asset.metadata.location!.latitude, longitude: asset.metadata.location!.longitude),
                   thumbnail: model.files[asset.id] ?? previews[asset.id], thumbnailBytes: model.thumbnailBytes[asset.id] ?? 0,
                   date: asset.metadata.creationDate)
        }) { ids, start in
            var urls: [URL] = []
            var shownIDs: [String] = []
            var bytes: [URL: UInt64] = [:]
            for id in ids {
                guard let url = model.files[id] ?? previews[id] else { continue }
                urls.append(url)
                shownIDs.append(id)
                bytes[url] = model.thumbnailBytes[id] ?? 0
            }
            guard let index = shownIDs.firstIndex(of: start) ?? (shownIDs.isEmpty ? nil : 0) else { return }
            viewer.open(.init(
                urls: urls, index: index, thumbnailBytes: bytes,
                date: { model.asset(shownIDs[$0])?.metadata.creationDate },
                name: { model.asset(shownIDs[$0])?.metadata.originalFilename ?? "" },
                info: { [MediaViewerHost.InfoRow(label: "Name", value: model.asset(shownIDs[$0])?.metadata.originalFilename ?? "")] }
            ))
        }
    }
}
