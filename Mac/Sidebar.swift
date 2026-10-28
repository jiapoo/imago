import ImagoKit
import SwiftUI

/// The window's sidebar: Home and the library's views, then two sections that fold. **Folders** is the
/// backup drive's folders as a tree, with Recently Deleted; drop photos on any of them. **iPhones** has a
/// compact row per iPhone that opens to its Photos and how its backup stands.
struct Sidebar: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    @Binding var selection: SidebarItem?
    @Binding var naming: FolderNaming?
    @Binding var showingAddPhone: Bool
    @AppStorage("sidebarFoldersExpanded") private var foldersExpanded = true
    @AppStorage("sidebarPhonesExpanded") private var phonesExpanded = true
    /// iPhones whose rows are open, by ID, comma-separated.
    @AppStorage("sidebarOpenPhones") private var openPhones = ""

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Home", systemImage: "house").tag(SidebarItem.home)
                Label("Library", systemImage: "photo.on.rectangle.angled").tag(SidebarItem.library)
                Label("Places", systemImage: "map").tag(SidebarItem.places)
                Label("On This Day", systemImage: "calendar.badge.clock").tag(SidebarItem.onThisDay)
                Label("Large Files", systemImage: "externaldrive.fill.badge.minus").tag(SidebarItem.large)
                StorageRow().tag(SidebarItem.storage)
            }

            Section("Folders", isExpanded: $foldersExpanded) {
                ForEach(library.folders) { folder in
                    FolderTree(folder: folder, selection: $selection, naming: $naming)
                }
                TrashRow().tag(SidebarItem.trash)
                Button { naming = .newFolder(moving: []) } label: {
                    Label("New Folder", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(!server.location.isAvailable)
            }

            Section("iPhones", isExpanded: $phonesExpanded) {
                ForEach(server.devices) { device in
                    PhoneSidebarItem(device: device, isOpen: openBinding(device.id), selection: selection)
                }
                Button { showingAddPhone = true } label: {
                    Label("Add iPhone", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 240)
    }

    private func openBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { openPhones.split(separator: ",").contains { $0 == id } },
            set: { open in
                var ids = Set(openPhones.split(separator: ",").map(String.init))
                if open { ids.insert(id) } else { ids.remove(id) }
                openPhones = ids.sorted().joined(separator: ",")
            }
        )
    }
}

// MARK: - Folders

/// A folder and the folders inside it. Opens while something is dragged over it.
private struct FolderTree: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    @Environment(FileHistory.self) private var history
    let folder: MediaLibrary.Folder
    @Binding var selection: SidebarItem?
    @Binding var naming: FolderNaming?
    @State private var expanded = false

    var body: some View {
        if let children = folder.children {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(children) { child in FolderTree(folder: child, selection: $selection, naming: $naming) }
            } label: {
                row
            }
            .springLoadingBehavior(.enabled)
        } else {
            row
        }
    }

    private var row: some View {
        FolderRow(folder: folder)
            .tag(SidebarItem.folder(folder.path))
            .contextMenu {
                Button("New Folder Inside…") { naming = .newFolder(moving: [], in: folder.path) }
                Button("Rename…") { naming = .rename(folder.path) }
                Button("Show in Finder") { server.revealInFinder(server.foldersURL.appending(path: folder.path)) }
                Divider()
                Button("Delete Folder", role: .destructive) {
                    if selection == .folder(folder.path) { selection = .library }
                    Task { history.record(await library.deleteFolder(folder.path, server: server)) }
                }
                .disabled(folder.count > 0 || folder.children != nil)
            }
    }
}

/// A folder's row. Drop photos or videos on it to copy or move them in (the toolbar's Copy | Move).
struct FolderRow: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    @Environment(FileHistory.self) private var history
    let folder: MediaLibrary.Folder
    @State private var targeted = false

    var body: some View {
        Label {
            HStack {
                Text(folder.name).lineLimit(1)
                Spacer()
                if folder.count > 0 {
                    Text(folder.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: targeted ? (TransferMode.current == .move ? "folder.fill.badge.minus" : "folder.fill.badge.plus") : "folder.fill")
                .foregroundStyle(.tint)
                .contentTransition(.symbolEffect(.replace))
        }
        .dropDestination(for: URL.self) { urls, _ in
            library.drop(urls, onto: .folder(folder.path), server: server, history: history)
        } isTargeted: { targeted = $0 }
    }
}

/// Recently Deleted. Drop photos or videos on it to delete them.
struct TrashRow: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    @Environment(FileHistory.self) private var history
    @State private var targeted = false

    var body: some View {
        Label {
            HStack {
                Text("Recently Deleted")
                Spacer()
                if !library.trash.isEmpty {
                    Text(library.trash.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: targeted ? "trash.fill" : "trash")
                .foregroundStyle(.tint)
                .contentTransition(.symbolEffect(.replace))
        }
        .dropDestination(for: URL.self) { urls, _ in
            library.drop(urls, onto: .trash, server: server, history: history)
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Show in Finder") { server.revealInFinder(server.trashURL) }
        }
    }
}

// MARK: - iPhones

/// An iPhone: just its name and a status light, opening to its Photos and how its backup stands.
private struct PhoneSidebarItem: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    let device: PairedDevice
    @Binding var isOpen: Bool
    let selection: SidebarItem?

    /// This iPhone, or one of its pages, is open.
    private var isSelected: Bool {
        selection == .device(device.id) || selection == .manage(device.id) || selection == .deletedOnPhone(device.id)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isOpen) {
            Label {
                Text("Photos")
            } icon: {
                Image(systemName: "photo.stack").foregroundStyle(server.color(of: device.id))
            }
            .tag(SidebarItem.manage(device.id))
            let deleted = library.deletedOnPhone(device.id).count
            if deleted > 0 {
                Label {
                    HStack {
                        Text("Deleted on iPhone")
                        Spacer()
                        Text(deleted.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "iphone.slash")
                }
                .tag(SidebarItem.deletedOnPhone(device.id))
                .help("Backed up here, but deleted on \(device.name) since")
            }
            // How its backup stands: only while this iPhone is open, to keep the sidebar short.
            if isSelected {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 4)
                    .selectionDisabled()
            }
        } label: {
            PhoneRow(device: device).tag(SidebarItem.device(device.id))
        }
    }

    /// How its backup stands, in a line.
    private var detail: String {
        let summary = server.summaries[device.id]
        var parts: [String] = []
        if let session = server.session(for: device) {
            parts.append(session.total == 0 ? "Comparing libraries…" : "Backing up \(session.received) of \(session.total)")
        } else if summary?.isPartial == true {
            parts.append("Backup not finished")
        } else if let last = summary?.lastBackup {
            parts.append("Backed up \(last.shortRelative)")
        } else {
            parts.append("No backup yet")
        }
        if let count = summary?.assetCount, count > 0 { parts.append("\(count.formatted()) items") }
        if server.liveDevices.contains(device.id) { parts.append("Imago open on it") }
        return parts.joined(separator: " · ")
    }
}

/// The iPhone's own row: a small icon tile, its name, and a light for how it stands. Drop its photos
/// on it to move them back into its folder.
struct PhoneRow: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    @Environment(FileHistory.self) private var history
    let device: PairedDevice
    @State private var targeted = false
    @State private var pickingColor = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: targeted ? "iphone.and.arrow.forward" : "iphone")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(server.color(of: device.id).ink)
                .frame(width: 22, height: 22)
                .background(server.color(of: device.id).gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentTransition(.symbolEffect(.replace))
            Text(device.name).lineLimit(1)
            Spacer(minLength: 0)
            status
        }
        .dropDestination(for: URL.self) { urls, _ in
            library.drop(urls, onto: .phoneFolder, server: server, history: history)
        } isTargeted: { targeted = $0 }
        .help(help)
        .contextMenu { DeviceColorMenu(device: device) { pickingColor = true } }
        .popover(isPresented: $pickingColor, arrowEdge: .trailing) { DeviceColorPicker(device: device) }
    }

    /// Backing up: a spinner. Otherwise a light: green while Imago is open on it, orange when a
    /// backup didn't finish.
    @ViewBuilder
    private var status: some View {
        if server.session(for: device) != nil {
            ProgressView().controlSize(.mini)
        } else if server.liveDevices.contains(device.id) {
            Circle().fill(.green).frame(width: 7, height: 7)
        } else if server.summaries[device.id]?.isPartial == true {
            Circle().fill(.orange).frame(width: 7, height: 7)
        }
    }

    private var help: String {
        if server.session(for: device) != nil { return "Backing up now" }
        if server.liveDevices.contains(device.id) { return "Imago is open on \(device.name)" }
        if server.summaries[device.id]?.isPartial == true { return "The last backup didn't finish" }
        return device.name
    }
}

/// In an iPhone's menus: its color as a row of swatches (as Finder shows tag colors), and More Colors…
/// for the whole palette.
struct DeviceColorMenu: View {
    @Environment(BackupServer.self) private var server
    let device: PairedDevice
    var more: () -> Void

    var body: some View {
        let current = server.colorHex(of: device.id)
        // A color from beyond the bright row shows as an extra swatch, picked.
        let swatches = PairedDevice.brights.contains { $0.hex == current }
            ? PairedDevice.brights : PairedDevice.brights + [.init(name: "Current Color", hex: current)]
        Picker("Color", selection: Binding(get: { current }, set: { server.setColor($0, for: device) })) {
            ForEach(swatches) { swatch in
                Image(nsImage: Self.swatch(swatch.color))
                    .accessibilityLabel(swatch.name)
                    .tag(swatch.hex)
            }
        }
        .pickerStyle(.palette)
        Button("More Colors…", action: more)
    }

    /// A round swatch, lit from the top. Menus draw SF Symbols in the text color, so the color needs an
    /// image of its own.
    private static func swatch(_ color: Color) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let base = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            NSGradient(starting: base.blended(withFraction: 0.25, of: .white) ?? base,
                       ending: base.blended(withFraction: 0.12, of: .black) ?? base)?.draw(in: circle, angle: -90)
            NSColor.black.withAlphaComponent(0.12).setStroke()
            circle.lineWidth = 0.75
            circle.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// The whole palette, in a popover: a grid of swatches, a preview of the iPhone in the color, and
/// the system color picker for any other. Changes show everywhere as they're made.
struct DeviceColorPicker: View {
    @Environment(BackupServer.self) private var server
    let device: PairedDevice
    @State private var hovered: String?

    var body: some View {
        let current = server.colorHex(of: device.id)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                let color = Color(hex: current)
                Image(systemName: "iphone")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color.ink)
                    .frame(width: 30, height: 30)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .animation(.snappy(duration: 0.2), value: current)
                Text(device.name).font(.headline).lineLimit(1)
            }

            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(PairedDevice.palette.indices, id: \.self) { row in
                    GridRow {
                        ForEach(PairedDevice.palette[row]) { swatch in
                            SwatchButton(swatch: swatch, selected: swatch.hex == current, hovered: hovered == swatch.hex) {
                                server.setColor(swatch.hex, for: device)
                            }
                            .onHover { hovered = $0 ? swatch.hex : (hovered == swatch.hex ? nil : hovered) }
                        }
                    }
                    if row == 2 { GridRow { Color.clear.frame(height: 0).gridCellColumns(8) } }
                }
            }

            Divider()

            HStack {
                Text("Custom").foregroundStyle(.secondary)
                Spacer()
                ColorPicker("Custom", selection: Binding(
                    get: { Color(hex: current) },
                    set: { server.setColor($0.hex, for: device) }
                ), supportsOpacity: false)
                .labelsHidden()
            }
        }
        .padding(16)
        .frame(width: 8 * 26 + 7 * 10 + 32)
    }
}

/// A round swatch in the palette: lit from the top, a ring in its own color when picked.
private struct SwatchButton: View {
    let swatch: PairedDevice.Swatch
    let selected: Bool
    let hovered: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(LinearGradient(colors: [swatch.color.mix(with: .white, by: 0.18), swatch.color.mix(with: .black, by: 0.08)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(swatch.color.ink)
                    }
                }
                .padding(selected ? 3 : 0)
                .overlay {
                    if selected { Circle().strokeBorder(swatch.color, lineWidth: 2) }
                }
                .frame(width: 26, height: 26)
                .scaleEffect(hovered && !selected ? 1.12 : 1)
                .shadow(color: swatch.color.opacity(hovered ? 0.45 : 0), radius: 5, y: 1)
                .animation(.snappy(duration: 0.15), value: hovered)
                .animation(.snappy(duration: 0.2), value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Storage, with the backup drive's name.
struct StorageRow: View {
    @Environment(BackupServer.self) private var server

    var body: some View {
        HStack {
            Label("Storage", systemImage: server.location.isAvailable ? "externaldrive" : "externaldrive.badge.exclamationmark")
            Spacer()
            Text(server.location.volumeName)
                .font(.caption)
                .foregroundStyle(server.location.isAvailable ? Color.secondary : Color.orange)
                .lineLimit(1)
        }
    }
}
