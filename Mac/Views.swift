import CoreImage.CIFilterBuiltins
import ImagoKit
import SwiftUI

enum SidebarItem: Hashable {
    case home
    case library
    /// Every iPhone's photos on a map.
    case places
    /// Taken on today's date in earlier years.
    case onThisDay
    case large
    case storage
    /// A folder inside Folders, by path ("Tennis/Serve").
    case folder(String)
    case trash
    case device(String)
    case manage(String)
    /// Backed up from an iPhone, but deleted on it since.
    case deletedOnPhone(String)
}

struct MainView: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    @Environment(MediaViewerHost.self) private var viewer
    @Environment(FileHistory.self) private var history
    @State private var selection: SidebarItem? = .home
    @State private var showingAddPhone = false
    @State private var naming: FolderNaming?
    @AppStorage(TransferMode.key) private var transferMode = TransferMode.copy.rawValue
    /// Move was picked: the alert explaining it is up.
    @State private var confirmingMoveMode = false

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection, naming: $naming, showingAddPhone: $showingAddPhone)
        } detail: {
            Group {
                switch selection ?? .home {
                case .home:
                    HomeView(showingAddPhone: $showingAddPhone, selection: $selection)
                case .library:
                    BrowserView(scope: .all)
                case .places:
                    LibraryPlacesView()
                case .onThisDay:
                    BrowserView(scope: .onThisDay)
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
                        DeviceView(device: device, openPhotos: { section in
                            PhoneLibraryModel.model(for: device).requestedSection = section
                            selection = .manage(device.id)
                        }, openDeleted: { selection = .deletedOnPhone(device.id) })
                        .id(id)
                    } else {
                        HomeView(showingAddPhone: $showingAddPhone, selection: $selection)
                    }
                case .deletedOnPhone(let id):
                    BrowserView(scope: .deletedOnPhone(id))
                case .manage(let id):
                    if let device = server.devices.first(where: { $0.id == id }) {
                        PhoneBrowserView(device: device).id(id)
                    } else {
                        HomeView(showingAddPhone: $showingAddPhone, selection: $selection)
                    }
                }
            }
            // A fresh view per sidebar item, so the last page's title and toolbar don't linger.
            .id(selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .mediaViewerOverlay()
            // What's under way (copying a big video, moving hundreds): above everything, bottom right.
            .overlay(alignment: .bottomTrailing) {
                if let activity = library.activity {
                    ActivityPanel(activity: activity)
                        .padding(20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: library.activity == nil)
            .toolbar {
                if !viewer.isOpen {
                    if pageHasPhotos {
                        ToolbarItem(placement: .primaryAction) { transferPicker }
                    }
                }
            }
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

    /// Pages of photos and videos, where Copy | Move applies. Not Home, Storage or an iPhone's own page.
    private var pageHasPhotos: Bool {
        switch selection ?? .home {
        case .library, .large, .folder, .trash, .manage, .deletedOnPhone, .onThisDay: true
        case .home, .storage, .device, .places: false
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

/// What's under way, while it lasts: what, how far (a bar), and the file being worked on.
struct ActivityPanel: View {
    let activity: MediaLibrary.Activity

    var body: some View {
        HStack(spacing: 14) {
            ProgressView(value: activity.fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.imago)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(activity.title).font(.headline)
                    Spacer(minLength: 12)
                    Text(activity.total > 1 ? "\(min(activity.done + 1, activity.total).formatted()) of \(activity.total.formatted())" : "")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                ProgressView(value: activity.fraction).tint(.imago)
                if let detail = activity.detail {
                    HStack {
                        Text(detail).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        if let bytes = activity.bytes {
                            Text("\(bytes.done.bytes) of \(bytes.total.bytes)").monospacedDigit()
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 18, y: 6)
    }
}

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
