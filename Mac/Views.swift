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
    /// The toolbar bell's list of what needs an answer.
    @State private var showingDecisions = false
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
                    BrowserView(scope: .folder(path), openFolder: { selection = .folder($0) })
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
            // An iPhone that connects gets its Not synced files.
            .onChange(of: server.liveDevices) { library.sendNotSynced(server) }
            // Turned to automatic: what's waiting on Deleted on iPhone is dealt with now.
            .onChange(of: server.acceptPhoneChanges) { Task { await library.load(from: server, force: true) } }
            // The folder on screen is gone (deleted or renamed in Finder): to the nearest folder it was
            // in that's still there, or Home.
            .onChange(of: library.folders) {
                guard library.state == .ready, case .folder(var path) = selection, !library.hasFolder(path) else { return }
                while !path.isEmpty, !library.hasFolder(path) { path = (path as NSString).deletingLastPathComponent }
                selection = path.isEmpty ? .home : .folder(path)
            }
            // Going to another page closes the viewer: it covers the page, so the new page wouldn't show.
            .onChange(of: selection) { if viewer.isOpen { viewer.finishClosing() } }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .mediaViewerOverlay()
            // What's under way (copying a big video, moving hundreds, saving an edited copy, an undo that
            // takes a while): one line at the bottom, above everything. Quick work never shows it.
            .overlay {
                ActivityOverlay(activity: library.activity ?? history.running.map { .init(title: $0, done: 0, total: 0, finishing: true) },
                                // Above a page's selection bar; in the viewer there's none.
                                bottomInset: viewer.isOpen ? 24 : 84)
            }
            .toolbar {
                // On every page, the viewer too: what Edit › Undo and Redo do, named in their help. In a
                // group of their own, apart from the viewer's Back.
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .navigation)
                }
                ToolbarItemGroup(placement: .navigation) {
                    Button { Task { await history.undo() } } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!history.canUndo)
                    .help(history.canUndo ? "\(history.undoTitle) (⌘Z)" : "Nothing to undo")
                    Button { Task { await history.redo() } } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!history.canRedo)
                    .help(history.canRedo ? "\(history.redoTitle) (⇧⌘Z)" : "Nothing to redo")
                }
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .navigation)
                }
                if !viewer.isOpen {
                    if pageHasPhotos {
                        ToolbarItem(placement: .primaryAction) { transferPicker }
                    }
                    // On every page while something waits for an answer: what the iPhones said no to,
                    // and what was deleted on them.
                    if decisionCount > 0 {
                        // In a group of its own, apart from each page's buttons.
                        if #available(macOS 26.0, *) {
                            ToolbarSpacer(.fixed, placement: .primaryAction)
                            ToolbarItem(placement: .primaryAction) { decisionsBell }
                                .sharedBackgroundVisibility(.visible)
                            ToolbarSpacer(.fixed, placement: .primaryAction)
                        } else {
                            ToolbarItem(placement: .primaryAction) { decisionsBell }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddPhone) { AddPhoneSheet() }
        .folderNameAlert($naming, library: library, server: server) { selection = .folder($0) }
        .confirmationDialog(duplicateTitle, isPresented: Binding(
            get: { library.duplicateQuestion != nil },
            set: { if !$0 { library.answerDuplicates(.cancel) } }
        ), titleVisibility: .visible) {
            Button("Skip Duplicates") { library.answerDuplicates(.skip) }
            Button("Keep Both") { library.answerDuplicates(.keepBoth) }
            Button("Replace") { library.answerDuplicates(.replace) }
            Button("Cancel", role: .cancel) { library.answerDuplicates(.cancel) }
        } message: {
            Text(duplicateMessage)
        }
        .alert("Move photos off the iPhone?", isPresented: $confirmingMoveMode) {
            Button("Use Move") { transferMode = TransferMode.move.rawValue }
            Button("Keep Copying", role: .cancel) {}
        } message: {
            Text("Photos and videos you drag or send to a folder will be moved there from their iPhone's backup, and the iPhone will be asked to delete them, freeing space on it. Each is checked against its backup first, you confirm on the iPhone, and they stay in Recently Deleted there for 30 days.")
        }
        .task(id: server.catalogRevision) { await library.load(from: server) }
        .focusEffectDisabled()
        #if DEBUG
        // Test hook: `Imago -OpenPlaces <iPhone folder>` opens that iPhone's Places (or `library` for all).
        .onAppear {
            let arguments = CommandLine.arguments
            guard let at = arguments.firstIndex(of: "-OpenPlaces"), arguments.indices.contains(at + 1) else { return }
            let name = arguments[at + 1]
            if name == "library" {
                selection = .places
            } else if let device = server.devices.first(where: { $0.folder == name || $0.name == name }) {
                PhoneLibraryModel.model(for: device).requestedSection = .places
                selection = .manage(device.id)
            }
        }
        #endif
    }

    /// Pages of photos and videos, where Copy | Move applies. Not Home, Storage or an iPhone's own page.
    /// How many things wait for an answer: each change an iPhone said no to, and each iPhone with
    /// photos deleted on it whose backups are still here.
    private var decisionCount: Int {
        library.declines.count + server.devices.count { device in
            library.deletedOnPhone(device.id).contains { !library.restoring.contains($0.id) }
        }
    }

    private var decisionsBell: some View {
        Button { showingDecisions.toggle() } label: {
            // The count on the bell's corner. A toolbar button clips what sticks out, so the bell
            // leaves room above and to its right, and the badge sits in that room, inside the button.
            Image(systemName: "bell.fill")
                .padding(.top, 7)
                .padding(.trailing, decisionCount > 9 ? 13 : 9)
                .overlay(alignment: .topTrailing) {
                    Text(decisionCount > 99 ? "99+" : decisionCount.formatted())
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(.red, in: Capsule())
                        // A ring in the toolbar's color keeps the badge apart from the bell under it.
                        .background(Color(nsColor: .windowBackgroundColor), in: Capsule().inset(by: -1.5))
                        .padding(1.5)
                }
                .padding(.horizontal, 2)
                .accessibilityLabel("Needs Your Answer")
                .accessibilityValue(decisionCount.formatted())
        }
        .help(decisionCount == 1 ? "1 thing needs your answer" : "\(decisionCount) things need your answer")
        .popover(isPresented: $showingDecisions, arrowEdge: .bottom) {
            ScrollView {
                DecisionsCard(devices: server.devices) { device in
                    showingDecisions = false
                    selection = .deletedOnPhone(device.id)
                }
                .padding(12)
            }
            .frame(width: 640)
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pageHasPhotos: Bool {
        switch selection ?? .home {
        case .library, .large, .folder, .trash, .manage, .deletedOnPhone, .onThisDay: true
        case .home, .storage, .device, .places: false
        }
    }

    private var duplicateTitle: String {
        guard let question = library.duplicateQuestion else { return "" }
        let folder = (question.folder as NSString).lastPathComponent
        return question.duplicates == question.total
            ? (question.total == 1 ? "“\(folder)” already has this file" : "“\(folder)” already has all \(question.total) files")
            : "\(question.duplicates) of \(question.total) files are already in “\(folder)”"
    }

    private var duplicateMessage: String {
        guard let question = library.duplicateQuestion else { return "" }
        let verb = question.isMove ? "moving" : "copying"
        return "They're exactly the same as files already there. Skip them and go on \(verb) the rest; keep both, and the new ones get a numbered name; or replace, and the ones already there go to Recently Deleted."
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

/// Long work (copying, moving, deleting, saving an edited copy, the library catching up): one line at
/// the bottom of the window, in the pill every notice uses (`StatusPill`), with the Mac's own small
/// spinner. It never covers the photos, and appears only once the work has taken a moment.
struct ActivityOverlay: View {
    let activity: MediaLibrary.Activity?
    /// Room left below it: above the selection bar, when there may be one.
    var bottomInset: CGFloat = 24
    @State private var shown: MediaLibrary.Activity?

    var body: some View {
        ZStack {
            if let shown {
                StatusPill(text: Self.line(shown),
                           mark: .progress(shown.total > 0 && !shown.finishing && (shown.total > 1 || shown.bytes != nil) ? shown.fraction : nil))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, bottomInset)
        .animation(.snappy(duration: 0.3), value: shown == nil)
        .allowsHitTesting(false)
        .task(id: activity == nil) {
            guard activity != nil else {
                shown = nil
                return
            }
            // Quick work (a move of a few items) would only flash.
            try? await Task.sleep(for: .milliseconds(450))
            if !Task.isCancelled { shown = activity }
        }
        .onChange(of: activity) { _, now in
            if shown != nil, let now { shown = now }
        }
    }

    /// "Copying to “Tennis” · 2 of 3", or how far one big file has got.
    static func line(_ activity: MediaLibrary.Activity) -> String {
        guard !activity.finishing else { return activity.title }
        if activity.total > 1 {
            return "\(activity.title) · \(min(activity.done + 1, activity.total).formatted()) of \(activity.total.formatted())"
        }
        if let bytes = activity.bytes, bytes.total > 0 {
            return "\(activity.title) · \((Double(bytes.done) / Double(bytes.total)).formatted(.percent.precision(.fractionLength(0))))"
        }
        return activity.title
    }
}

/// How far long work has got, in the pill: a thin silver ring that fills, the weight of the text beside
/// it. (The system's determinate circle draws a filled wedge.)
private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.04, min(1, fraction)))
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

/// The one way Imago says what it's doing or has done: a small pill with one line, floating at the
/// bottom. Long work shows the Mac's spinner (filling when it knows how far it is); a finished thing a
/// check mark.
struct StatusPill: View {
    enum Mark: Equatable {
        /// Under way: how far, when known.
        case progress(Double?)
        case done
        case failed
    }

    let text: String
    var mark: Mark = .done

    var body: some View {
        HStack(spacing: 9) {
            switch mark {
            case .progress(let fraction?):
                ProgressRing(fraction: fraction)
            case .progress(nil):
                ProgressView().controlSize(.small)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.secondary)
            }
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.numericText())
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .animation(.snappy(duration: 0.25), value: text)
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
            Tab("Changes", systemImage: "arrow.down.left.arrow.up.right") {
                ChangesSettings()
            }
        }
        .frame(width: 720, height: 640)
        .focusEffectDisabled()
    }
}

/// Whether changes made on the iPhones are made here by themselves, or wait for the user.
private struct ChangesSettings: View {
    @Environment(BackupServer.self) private var server

    var body: some View {
        @Bindable var server = server
        VStack(alignment: .leading, spacing: 16) {
            Label("Changes from iPhones", systemImage: "arrow.down.left.arrow.up.right")
                .font(.title2.bold())
            Picker("Photos deleted on an iPhone", selection: $server.acceptPhoneChanges) {
                Text("Ask First").tag(false)
                Text("Apply Automatically").tag(true)
            }
            .pickerStyle(.radioGroup)
            Text(server.acceptPhoneChanges
                 ? "Their backups on this Mac go straight to Recently Deleted, where you can put them back for \(server.trashDays > 0 ? "\(server.trashDays) days" : "as long as you like")."
                 : "Their backups stay on this Mac, and the bell asks whether to delete them here too, keep them, or put them back on the iPhone.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Each iPhone has its own setting for changes made on this Mac, in Imago on the iPhone.")
                .font(.callout).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
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
