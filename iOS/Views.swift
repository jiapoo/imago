import ImagoKit
import SwiftUI
import VisionKit

struct ContentView: View {
    @Environment(BackupClient.self) private var client
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPairing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if client.credential == nil {
                        WelcomeCard { showingPairing = true }
                    } else {
                        StatusHero()
                        if !client.macChanges.isEmpty { MacChangesCard() }
                    }
                    StorageCard()
                    if client.credential != nil {
                        SettingsCard()
                        MacCard()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(alignment: .top) {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.22), Color(.systemGroupedBackground)],
                    startPoint: .top, endPoint: .init(x: 0.5, y: 0.45)
                )
                .ignoresSafeArea()
            }
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingPairing) { PairingSheet() }
            .task { await client.refreshCounts() }
            .refreshable { await client.refreshCounts() }
            // Back from Settings, the photo-access prompt or another app: the library may have changed.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await client.refreshCounts() } }
            }
        }
    }
}

extension View {
    func card() -> some View {
        self
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }
}

// MARK: - Hero

struct StatusHero: View {
    @Environment(BackupClient.self) private var client

    var body: some View {
        let state = heroState
        VStack(spacing: 18) {
            ProgressRing(progress: state.progress, symbol: state.symbol, tint: state.tint, busy: client.phase.isRunning)
                .padding(.top, 8)
            VStack(spacing: 6) {
                Text(state.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .contentTransition(.numericText())
                Text(state.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            Button {
                Task { await client.backUpNow() }
            } label: {
                Label(buttonTitle, systemImage: "arrow.up.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(client.phase.isRunning)
            if case .waitingToRetry = client.phase {
                Button("Connect Now", systemImage: "arrow.clockwise") { client.retryNow() }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
            if client.phase.isRunning {
                Label(runningNote, systemImage: "lock.open.display")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .card()
        .animation(.smooth, value: client.phase)
    }

    private var buttonTitle: String {
        if client.phase.isRunning { return "Backing Up…" }
        return client.unfinished == nil ? "Back Up Now" : "Resume Backup"
    }

    private var runningNote: String {
        if #available(iOS 26, *) {
            return "You can leave the app; progress shows at the top of the screen. If anything stops it, it picks up where it left off."
        }
        return "Keep Imago open; your iPhone won't lock while it backs up. If anything stops it, it picks up where it left off."
    }

    private struct HeroState {
        var symbol: String
        var tint: Color
        var title: String
        var subtitle: String
        var progress: Double?
    }

    private var heroState: HeroState {
        let mac = client.credential?.serverName ?? "your Mac"
        switch client.phase {
        case .idle:
            if let paused = client.unfinished {
                return HeroState(symbol: "pause.fill", tint: .orange, title: "Backup paused",
                                 subtitle: "\(paused.done.formatted()) of \(paused.total.formatted()) photos and videos are on \(mac). Resume to continue where it stopped.",
                                 progress: Double(paused.done) / Double(max(paused.total, 1)))
            }
            if let last = client.lastBackup {
                return HeroState(symbol: "checkmark.shield.fill", tint: .green, title: "Backed up",
                                 subtitle: "Last backup to \(mac) \(last.formatted(.relative(presentation: .named))).", progress: 1)
            }
            return HeroState(symbol: "arrow.up", tint: .accentColor, title: "Ready to back up",
                             subtitle: "Your first backup copies everything to \(mac).", progress: 0)
        case .searching:
            return HeroState(symbol: "wifi", tint: .accentColor, title: "Looking for \(mac)…",
                             subtitle: "Make sure it's on and on the same Wi-Fi.")
        case .connecting:
            return HeroState(symbol: "lock.fill", tint: .accentColor, title: "Connecting securely…", subtitle: mac)
        case .comparing:
            return HeroState(symbol: "arrow.left.arrow.right", tint: .accentColor, title: "Comparing libraries…",
                             subtitle: "Finding what \(mac) doesn't have yet.")
        case .uploading(let done, let total, let current):
            return HeroState(symbol: "arrow.up", tint: .accentColor, title: "\(done.formatted()) of \(total.formatted())",
                             subtitle: current, progress: Double(done) / Double(max(total, 1)))
        case .waitingToRetry(let attempt, let seconds, let reason):
            return HeroState(symbol: "wifi.exclamationmark", tint: .orange, title: "Reconnecting in \(seconds)s",
                             subtitle: "\(reason) Attempt \(attempt + 1); nothing already sent is lost.",
                             progress: client.unfinished.map { Double($0.done) / Double(max($0.total, 1)) } ?? 0)
        case .finished(let sent, let failed):
            let title = sent == 0 ? "Everything's backed up" : "Backed up \(sent) \(sent == 1 ? "item" : "items")"
            let subtitle = failed > 0
                ? "\(failed) couldn't be copied and will be retried next time."
                : "Every photo and video is safe on \(mac)."
            return HeroState(symbol: "checkmark.shield.fill", tint: failed > 0 ? .orange : .green, title: title, subtitle: subtitle, progress: 1)
        case .failed(let message):
            let progress = client.unfinished.map { Double($0.done) / Double(max($0.total, 1)) } ?? 1
            return HeroState(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Backup didn't finish",
                             subtitle: message, progress: progress)
        }
    }
}

struct ProgressRing: View {
    var progress: Double?
    var symbol: String
    var tint: Color
    var busy: Bool
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.08))
            Circle()
                .stroke(tint.opacity(0.15), lineWidth: 12)
            Circle()
                .trim(from: 0, to: progress ?? 0.28)
                .stroke(
                    // A full ring gets a solid color so the gradient's start and end don't meet at a seam.
                    progress == 1 ? AnyShapeStyle(tint) : AnyShapeStyle(AngularGradient(colors: [tint.opacity(0.55), tint], center: .center)),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .rotationEffect(.degrees(progress == nil && spin ? 360 : 0))
                .animation(progress == nil ? .linear(duration: 1.1).repeatForever(autoreverses: false) : .smooth, value: spin)
                .animation(.smooth, value: progress)
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: busy)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 132, height: 132)
        .onAppear { spin = true }
    }
}

struct WelcomeCard: View {
    let pair: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "iphone")
                Image(systemName: "arrow.right")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.secondary)
                Image(systemName: "desktopcomputer")
            }
            .font(.system(size: 52, weight: .regular))
            .foregroundStyle(.tint)
            .padding(.top, 12)

            VStack(spacing: 8) {
                Text("Back up to your Mac")
                    .font(.title.weight(.bold))
                Text("Your photos and videos copy to your own Mac over Wi-Fi, encrypted, at full quality. Nothing goes through the cloud.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: pair) {
                Label("Pair with Mac", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)

            Text("On your Mac, open Imago and click **Add iPhone**.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .card()
    }
}

// MARK: - Cards

/// What photos and videos take up on this iPhone, and how much space is free.
struct StorageCard: View {
    @Environment(BackupClient.self) private var client

    var body: some View {
        let storage = client.storage
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iPhone Storage").font(.headline)
                    if let storage, storage.totalBytes > 0 {
                        Text("\(byteText(storage.totalBytes - storage.freeBytes)) of \(byteText(storage.totalBytes)) used")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let storage, storage.totalBytes > 0 {
                    Text("\(byteText(storage.freeBytes)) free")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                        .contentTransition(.numericText())
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                StorageBar(storage: storage)
                HStack(spacing: 14) {
                    LegendDot(tint: .blue, title: "Photos")
                    LegendDot(tint: .pink, title: "Videos")
                    LegendDot(tint: Color(.systemGray3), title: "Other")
                    LegendDot(tint: Color(.tertiarySystemFill), title: "Free")
                }
            }

            VStack(spacing: 0) {
                StorageRow(symbol: "square.stack.fill", tint: .indigo, title: "All",
                           count: client.photoCount + client.videoCount, bytes: storage.map { $0.photoBytes + $0.videoBytes })
                Divider().padding(.leading, 50)
                StorageRow(symbol: "photo.fill", tint: .blue, title: "Photos",
                           count: client.photoCount, bytes: storage?.photoBytes)
                Divider().padding(.leading, 50)
                StorageRow(symbol: "video.fill", tint: .pink, title: "Videos",
                           count: client.videoCount, bytes: storage?.videoBytes)
            }
        }
        .card()
        .animation(.smooth, value: storage)
    }
}

/// The disk as one capsule: photos, then videos, then everything else, with the free space left empty.
struct StorageBar: View {
    let storage: BackupClient.Storage?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                if let storage, storage.totalBytes > 0 {
                    segment(storage.photoBytes, of: storage, width: geometry.size.width, tint: .blue)
                    segment(storage.videoBytes, of: storage, width: geometry.size.width, tint: .pink)
                    segment(storage.otherBytes, of: storage, width: geometry.size.width, tint: Color(.systemGray3))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 14)
        .background(Color(.tertiarySystemFill))
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private func segment(_ part: Int64, of storage: BackupClient.Storage, width: CGFloat, tint: Color) -> some View {
        Rectangle()
            .fill(tint.gradient)
            .frame(width: part > 0 ? max(width * CGFloat(part) / CGFloat(storage.totalBytes), 3) : 0)
    }

    private var accessibilityText: String {
        guard let storage, storage.totalBytes > 0 else { return "Measuring storage" }
        return "Photos \(byteText(storage.photoBytes)), videos \(byteText(storage.videoBytes)), other \(byteText(storage.otherBytes)), \(byteText(storage.freeBytes)) free"
    }
}

struct StorageRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let count: Int
    /// Nil until the library has been measured.
    let bytes: Int64?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                Text("\(count.formatted()) \(count == 1 ? "item" : "items")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            if let bytes {
                Text(byteText(bytes))
                    .font(.body.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }
}

struct LegendDot: View {
    let tint: Color
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// "12.4 GB", as Settings writes sizes.
func byteText(_ count: Int64) -> String {
    count == 0 ? "0 KB" : count.formatted(.byteCount(style: .file))
}

/// The two switches, as rows in one card.
struct SettingsCard: View {
    @Environment(BackupClient.self) private var client

    var body: some View {
        @Bindable var client = client
        VStack(spacing: 0) {
            SettingRow(symbol: "moon.stars.fill", tint: .indigo, title: "Back up overnight", isOn: $client.overnightBackup,
                       note: client.overnightBackup ? "While charging on Wi-Fi. \(lastRunText)" : "While charging on Wi-Fi, when iOS allows.")
            Divider().padding(.leading, 50)
            SettingRow(symbol: "arrow.down.left.arrow.up.right", tint: .orange, title: "Apply changes from Mac", isOn: $client.applyRightAway,
                       note: client.applyRightAway ? "Favorites and albums right away. Deletions always ask first." : "Changes wait here for you to review them.")
        }
        .card()
    }

    private var lastRunText: String {
        guard let date = client.lastAutomaticRun else { return "Hasn't run yet." }
        return "Last ran \(date.formatted(.relative(presentation: .named)))."
    }
}

struct SettingRow: View {
    let symbol: String
    let tint: Color
    let title: String
    @Binding var isOn: Bool
    let note: String

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(tint)
        .padding(.vertical, 8)
    }
}

/// The paired Mac, whether it's connected now, and the name this iPhone has there.
struct MacCard: View {
    @Environment(BackupClient.self) private var client
    @Environment(LiveLink.self) private var live
    @State private var confirmingUnpair = false

    var body: some View {
        @Bindable var client = client
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(client.credential?.serverName ?? "Mac").font(.headline)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(statusText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    Button("Unpair", systemImage: "xmark.circle", role: .destructive) { confirmingUnpair = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
            }
            HStack {
                Text("Name on Mac").foregroundStyle(.secondary)
                TextField("iPhone", text: $client.deviceName)
                    .multilineTextAlignment(.trailing)
                    .font(.body.weight(.medium))
                    .submitLabel(.done)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .card()
        .confirmationDialog("Unpair from \(client.credential?.serverName ?? "Mac")?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { client.unpair() }
        } message: {
            Text("Photos already on the Mac stay there. You can pair again anytime.")
        }
    }

    private var statusColor: Color {
        switch live.state {
        case .connected: .green
        case .connecting: .orange
        case .off: Color(.systemGray3)
        }
    }

    private var statusText: String {
        switch live.state {
        case .connected: "Connected"
        case .connecting: "Looking for it…"
        case .off: "Not connected · backs up on the same Wi-Fi"
        }
    }
}

// MARK: - Pairing

struct PairingSheet: View {
    @Environment(BackupClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var pastedLink = ""
    @State private var code: PairingInfo?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let code {
                    NameStep(code: code, errorMessage: errorMessage, pair: pair)
                } else {
                    scanStep
                }
            }
            .padding(24)
            .animation(.smooth, value: code)
            .navigationTitle("Pair with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private var scanStep: some View {
        VStack(spacing: 20) {
            if DataScannerViewController.isSupported {
                QRScanner { text in
                    if code == nil, let scanned = PairingInfo(qrString: text) { code = scanned }
                }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 4, dash: [40, 200]))
                        .frame(width: 240, height: 240)
                }
                .frame(maxHeight: 420)
                Text("Point at the code in **Add iPhone** on your Mac.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 56)).foregroundStyle(.tint)
                Text("On your Mac, click **Copy Link** in Add iPhone, then paste it here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                TextField("photobackup://pair?…", text: $pastedLink, axis: .vertical)
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .lineLimit(2...5)
                Button {
                    code = PairingInfo(qrString: pastedLink)
                } label: {
                    Text("Continue").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(PairingInfo(qrString: pastedLink) == nil)
            }
            Spacer()
        }
    }

    private func pair() {
        guard let code, !client.isPairing else { return }
        errorMessage = nil
        Task {
            do {
                try await client.pair(with: code)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Confirms how this iPhone appears on the Mac. The name also becomes its backup folder.
private struct NameStep: View {
    @Environment(BackupClient.self) private var client
    let code: PairingInfo
    let errorMessage: String?
    let pair: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        @Bindable var client = client
        VStack(spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "iphone")
                Image(systemName: "link")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.secondary)
                Image(systemName: "desktopcomputer")
            }
            .font(.system(size: 44))
            .foregroundStyle(.tint)
            .padding(.top, 8)

            VStack(spacing: 6) {
                Text("Pair with \(code.serverName)").font(.title2.bold()).multilineTextAlignment(.center)
                Text("Your Mac shows this iPhone by this name and saves its photos in a folder with the same name.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("iPhone name").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                TextField("e.g. Jia's iPhone", text: $client.deviceName)
                    .font(.title3.weight(.medium))
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .focused($nameFocused)
                    .submitLabel(.go)
                    .onSubmit { if !client.hasGenericName { pair() } }
                if client.hasGenericName {
                    Label("Give it a name you'll recognize, especially if you pair more than one iPhone.", systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Button(action: pair) {
                Group {
                    if client.isPairing {
                        ProgressView().tint(.white)
                    } else {
                        Text("Pair").font(.headline)
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(client.deviceName.trimmingCharacters(in: .whitespaces).isEmpty || client.isPairing)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            Spacer()
        }
        .onAppear {
            // Only the model name is known: clear it so the user types a real one.
            if client.hasGenericName {
                client.deviceName = ""
                nameFocused = true
            }
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            isHighlightingEnabled: false
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in items {
                if let value = barcode.payloadStringValue { onCode(value) }
            }
        }
    }
}
