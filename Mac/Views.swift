import CoreImage.CIFilterBuiltins
import ImagoKit
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case library
    case large
    case storage
    /// A folder inside Folders, by path ("Tennis/Serve").
    case folder(String)
    case trash
    case device(String)
    case manage(String)
}

struct MainView: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    @Environment(MediaViewerHost.self) private var viewer
    @Environment(FileHistory.self) private var history
    @State private var selection: SidebarItem? = .overview
    @State private var showingAddPhone = false
    @State private var naming: FolderNaming?
    @AppStorage("showsFilesPanel") private var showsFilesPanel = true
    @AppStorage(TransferMode.key) private var transferMode = TransferMode.copy.rawValue
    /// Move was picked: the alert explaining it is up.
    @State private var confirmingMoveMode = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Overview", systemImage: "checkmark.shield").tag(SidebarItem.overview)
                    Label("Library", systemImage: "photo.on.rectangle.angled").tag(SidebarItem.library)
                    Label("Large Files", systemImage: "externaldrive.fill.badge.minus").tag(SidebarItem.large)
                    StorageRow().tag(SidebarItem.storage)
                }
                Section("Folders") {
                    ForEach(library.folders) { folder in
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
                    TrashRow().tag(SidebarItem.trash)
                    Button { naming = .newFolder(moving: []) } label: {
                        Label("New Folder", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(!server.location.isAvailable)
                }
                Section("iPhones") {
                    ForEach(server.devices) { device in
                        DeviceRow(device: device).tag(SidebarItem.device(device.id))
                        Label("Photos", systemImage: "photo.stack")
                            .padding(.leading, 32)
                            .tag(SidebarItem.manage(device.id))
                    }
                    Button { showingAddPhone = true } label: {
                        Label("Add iPhone", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview:
                    OverviewView(showingAddPhone: $showingAddPhone, selection: $selection)
                case .library:
                    BrowserView(scope: .all)
                case .large:
                    BrowserView(scope: .large)
                case .folder(let path):
                    BrowserView(scope: .folder(path))
                case .trash:
                    BrowserView(scope: .trash)
                case .storage:
                    StorageView()
                case .device(let id):
                    if let device = server.devices.first(where: { $0.id == id }) {
                        DeviceView(device: device) { section in
                            PhoneLibraryModel.model(for: device).requestedSection = section
                            selection = .manage(device.id)
                        }
                        .id(id)
                    } else {
                        OverviewView(showingAddPhone: $showingAddPhone, selection: $selection)
                    }
                case .manage(let id):
                    if let device = server.devices.first(where: { $0.id == id }) {
                        PhoneBrowserView(device: device).id(id)
                    } else {
                        OverviewView(showingAddPhone: $showingAddPhone, selection: $selection)
                    }
                }
            }
            // A fresh view per sidebar item, so the last page's title and toolbar don't linger.
            .id(selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .mediaViewerOverlay()
            .toolbar {
                if !viewer.isOpen {
                    if pageHasPhotos {
                        ToolbarItem(placement: .primaryAction) { transferPicker }
                    }
                    // With the panel open, its own toolbar holds this, at the window's right end.
                    if !showsFilesPanel, pageHasPhotos {
                        ToolbarItem(placement: .primaryAction) { FilesPanelToggle(isShown: $showsFilesPanel) }
                    }
                }
            }
        }
        // The backup drive's folders on the right, full height like the sidebar (hidden while viewing a photo).
        .inspector(isPresented: Binding(get: { showsFilesPanel && pageHasPhotos && !viewer.isOpen }, set: { showsFilesPanel = $0 })) {
            FilesPanel(selection: $selection, isShown: $showsFilesPanel)
                .inspectorColumnWidth(min: 220, ideal: 270, max: 400)
        }
        .sheet(isPresented: $showingAddPhone) { AddPhoneSheet() }
        .folderNameAlert($naming, library: library, server: server) { selection = .folder($0) }
        .alert("Move photos off the iPhone?", isPresented: $confirmingMoveMode) {
            Button("Use Move") { transferMode = TransferMode.move.rawValue }
            Button("Keep Copying", role: .cancel) {}
        } message: {
            Text("Photos and videos you drag or send to a folder will be moved there from their iPhone's backup, and the iPhone will be asked to delete them, freeing space on it. Each is checked against its backup first, you confirm on the iPhone, and they stay in Recently Deleted there for 30 days.")
        }
        .task(id: server.catalogRevision) { await library.load(from: server) }
        .focusEffectDisabled()
    }

    /// Pages of photos and videos, where the Files panel is there to drop them into folders. Not the
    /// Overview, Storage or an iPhone's own page.
    private var pageHasPhotos: Bool {
        switch selection ?? .overview {
        case .library, .large, .folder, .trash, .manage: true
        case .overview, .storage, .device: false
        }
    }

    /// Copy | Move: what putting photos into a folder does. Move asks first.
    private var transferPicker: some View {
        Picker("Into folders", selection: Binding(
            get: { transferMode },
            set: { new in
                if new == TransferMode.move.rawValue, transferMode != new { confirmingMoveMode = true } else { transferMode = new }
            }
        )) {
            Text("Copy").tag(TransferMode.copy.rawValue)
            Text("Move").tag(TransferMode.move.rawValue)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help(transferMode == TransferMode.move.rawValue
              ? "Move: photos put into a folder leave the iPhone's backup and are deleted from the iPhone"
              : "Copy: photos put into a folder are copied there; the iPhone keeps them")
    }
}

/// Shows or hides the Files panel.
struct FilesPanelToggle: View {
    @Binding var isShown: Bool

    var body: some View {
        Button { isShown.toggle() } label: { Label("Files", systemImage: "sidebar.right") }
            .help(isShown ? "Hide the backup drive's folders" : "Show the backup drive's folders, to drop photos into")
    }
}

/// A Folder in the sidebar. Drop photos or videos on it to move them in.
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
            Image(systemName: targeted ? "folder.fill.badge.plus" : "folder.fill")
                .foregroundStyle(.tint)
                .contentTransition(.symbolEffect(.replace))
        }
        .dropDestination(for: URL.self) { urls, _ in
            library.drop(urls, onto: .folder(folder.path), server: server, history: history)
        } isTargeted: { targeted = $0 }
    }
}

/// Recently Deleted in the sidebar. Drop photos or videos on it to delete them.
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
    }
}

struct DeviceRow: View {
    @Environment(BackupServer.self) private var server
    let device: PairedDevice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if server.session(for: device) != nil {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let summary = server.summaries[device.id]
        if summary?.isPartial == true, let count = summary?.assetCount { return "\(count.formatted()) so far · not finished" }
        if let last = summary?.lastBackup { return "Backed up \(last.shortRelative)" }
        return "No backup yet"
    }
}

// MARK: - Overview

struct OverviewView: View {
    @Environment(BackupServer.self) private var server
    @Binding var showingAddPhone: Bool
    @Binding var selection: SidebarItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeroCard(showingAddPhone: $showingAddPhone)

                HStack(spacing: 16) {
                    StatTile(title: "Photos & videos", value: server.totalAssets.formatted(), symbol: "photo.stack.fill", tint: .blue)
                    StatTile(title: "Space used", value: server.totalBytes.bytes, symbol: "chart.pie.fill", tint: .purple)
                    StatTile(title: server.devices.count == 1 ? "iPhone" : "iPhones", value: "\(server.devices.count)", symbol: "iphone", tint: .orange)
                }

                if server.isBackingUp { TransfersCard() }
                LocationCard { selection = .storage }
                ActivityCard()
            }
            .padding(28)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
    }
}

struct HeroCard: View {
    @Environment(BackupServer.self) private var server
    @Binding var showingAddPhone: Bool

    var body: some View {
        let health = server.health
        HStack(spacing: 22) {
            HealthBadge(symbol: health.symbol, tint: health.tint, size: 76, spinning: server.isBackingUp)
            VStack(alignment: .leading, spacing: 6) {
                Text(health.title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(health.subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if server.devices.isEmpty {
                    Button("Add iPhone") { showingAddPhone = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(
                    colors: [health.tint.opacity(0.20), health.tint.opacity(0.05)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
        }
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(health.tint.opacity(0.18)))
        .animation(.smooth, value: health.title)
    }
}

struct TransfersCard: View {
    @Environment(BackupServer.self) private var server

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Backing up now", symbol: "arrow.up.circle")
            ForEach(Array(server.sessions.values).filter { $0.deviceID != nil }) { session in
                let name = server.devices.first { $0.id == session.deviceID }?.name ?? "iPhone"
                HStack(spacing: 14) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.title2).foregroundStyle(.tint).frame(width: 30)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(name).font(.headline)
                            Spacer()
                            Text(session.total == 0 ? "Comparing…" : "\(session.received) of \(session.total)")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(session.received), total: Double(max(session.total, 1)))
                            .tint(.blue)
                        if let file = session.currentFile {
                            Text(file).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .card()
    }
}

struct LocationCard: View {
    @Environment(BackupServer.self) private var server
    /// Opens the Storage page.
    var manage: () -> Void

    var body: some View {
        let location = server.location
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionHeader(title: "Backup location", symbol: "folder")
                Spacer()
                if location.isAvailable {
                    Button("Show in Finder") { server.revealInFinder() }
                }
                Button("Change…") { manage() }
                    .help("Choose a folder, external drive or network drive")
            }

            HStack(spacing: 16) {
                Image(systemName: location.symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(location.isAvailable ? Color.teal : .orange)
                    .frame(width: 56, height: 56)
                    .background((location.isAvailable ? Color.teal : .orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(location.volumeName).font(.title3.weight(.semibold))
                    Text(location.displayPath)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(location.kindDescription).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            if !location.isAvailable {
                Label("“\(location.volumeName)” isn't connected. Backups resume automatically when you plug it in.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else if let used = location.usedFraction, let free = location.availableBytes, let total = location.totalBytes {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: used)
                        .tint(used > 0.9 ? .red : used > 0.75 ? .orange : .teal)
                    Text("\(free.formatted(.byteCount(style: .file))) free of \(total.formatted(.byteCount(style: .file)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

        }
        .card()
    }
}

struct ActivityCard: View {
    @Environment(BackupServer.self) private var server

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Activity", symbol: "clock.arrow.circlepath")
            if server.log.isEmpty {
                Text("Nothing yet. Activity from this session shows up here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(server.log.prefix(8)) { line in
                HStack(spacing: 12) {
                    Image(systemName: line.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(line.text).lineLimit(2)
                    Spacer()
                    Text(line.date, style: .time)
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .font(.callout)
            }
        }
        .card()
    }
}

// MARK: - Device

struct AddPhoneSheet: View {
    @Environment(BackupServer.self) private var server
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 26) {
            if let paired = server.justPaired {
                VStack(spacing: 14) {
                    HealthBadge(symbol: "checkmark", tint: .green, size: 80)
                    Text("Paired with \(paired.name)").font(.title.bold())
                    Text("Its photos go to the “\(paired.folder)” folder. It stays paired until you remove it, and backs up whenever it's on the same network as this Mac.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 400)
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .padding(.top, 6)
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                Text("Add an iPhone").font(.system(size: 26, weight: .bold, design: .rounded))
                HStack(alignment: .center, spacing: 36) {
                    Group {
                        if let code = server.pairingCode, let image = Self.qrImage(code.qrString) {
                            Image(nsImage: image).interpolation(.none).resizable()
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(width: 200, height: 200)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 6)

                    VStack(alignment: .leading, spacing: 18) {
                        Step(number: 1, text: "Open Imago on your iPhone")
                        Step(number: 2, text: "Tap **Pair with Mac**")
                        Step(number: 3, text: "Point the camera at this code")
                        Label("Keep both on the same Wi-Fi. This code works once, and only while this window is open.", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 260)
                }
                HStack {
                    Button("Copy Link") {
                        // For the iOS Simulator, which has no camera.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(server.pairingCode?.qrString ?? "", forType: .string)
                    }
                    .help("Copy the pairing link to paste into the iOS Simulator")
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(32)
        .frame(width: 600)
        .animation(.spring(duration: 0.4), value: server.justPaired)
        .onAppear { server.beginPairing() }
        .onDisappear { server.endPairing() }
        .focusEffectDisabled()
    }

    static func qrImage(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)))
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.blue, in: Circle())
            Text(text)
        }
    }
}

// MARK: - Menu bar

struct MenuBarPanel: View {
    @Environment(BackupServer.self) private var server
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let health = server.health
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                HealthBadge(symbol: health.symbol, tint: health.tint, size: 40, spinning: server.isBackingUp)
                VStack(alignment: .leading, spacing: 2) {
                    Text(health.title).font(.headline)
                    Text("\(server.totalAssets.formatted()) items · \(server.totalBytes.bytes)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            ForEach(Array(server.sessions.values).filter { $0.deviceID != nil }) { session in
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.devices.first { $0.id == session.deviceID }?.name ?? "iPhone").font(.caption.weight(.medium))
                    ProgressView(value: Double(session.received), total: Double(max(session.total, 1)))
                }
            }

            if !server.devices.isEmpty {
                Divider()
                ForEach(server.devices) { device in
                    HStack {
                        Image(systemName: "iphone").foregroundStyle(.secondary)
                        Text(device.name).lineLimit(1)
                        Spacer()
                        Text(server.summaries[device.id].map { $0.isPartial ? "Not finished" : ($0.lastBackup?.shortRelative ?? "Never") } ?? "Never")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }

            Divider()
            HStack {
                Button("Open Imago") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("Quit Imago")
            }
        }
        .padding(16)
        .frame(width: 300)
        .focusEffectDisabled()
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Storage", systemImage: "externaldrive") {
                StorageView()
            }
            Tab("Overnight", systemImage: "moon.stars") {
                OvernightSettings()
            }
        }
        .frame(width: 720, height: 640)
        .focusEffectDisabled()
    }
}

private struct OvernightSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Overnight backups", systemImage: "moon.stars.fill")
                .font(.title2.bold())
            Text("iPhones back up on their own while charging on Wi-Fi, usually at night. While one is backing up, Imago keeps this Mac from going to sleep.")
            Text("To let a sleeping Mac accept backups, turn on **Wake for network access** in System Settings › Energy.")
            Button("Open Energy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Energy-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            Spacer()
        }
        .foregroundStyle(.primary)
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Sidebar row for Storage: shows which drive is in use, and warns when it's unplugged.
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
