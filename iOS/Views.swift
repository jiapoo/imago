import PhotoBackupKit
import SwiftUI
import VisionKit

struct ContentView: View {
    @Environment(BackupClient.self) private var client
    @State private var showingPairing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if client.credential == nil {
                        WelcomeCard { showingPairing = true }
                    } else {
                        StatusHero()
                        if !client.macChanges.isEmpty { MacChangesCard() }
                    }
                    LibraryCard()
                    if client.credential != nil {
                        OvernightCard()
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
            .navigationTitle("Photo Backup")
            .sheet(isPresented: $showingPairing) { PairingSheet() }
            .task { await client.refreshCounts() }
            .refreshable { await client.refreshCounts() }
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
        return "Keep Photo Backup open; your iPhone won't lock while it backs up. If anything stops it, it picks up where it left off."
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
                .stroke(tint.opacity(0.15), lineWidth: 14)
            Circle()
                .trim(from: 0, to: progress ?? 0.28)
                .stroke(
                    // A full ring gets a solid color so the gradient's start and end don't meet at a seam.
                    progress == 1 ? AnyShapeStyle(tint) : AnyShapeStyle(AngularGradient(colors: [tint.opacity(0.55), tint], center: .center)),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .rotationEffect(.degrees(progress == nil && spin ? 360 : 0))
                .animation(progress == nil ? .linear(duration: 1.1).repeatForever(autoreverses: false) : .smooth, value: spin)
                .animation(.smooth, value: progress)
            Image(systemName: symbol)
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: busy)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 168, height: 168)
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

            Text("On your Mac, open Photo Backup and click **Add iPhone**.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .card()
    }
}

// MARK: - Cards

struct LibraryCard: View {
    @Environment(BackupClient.self) private var client

    var body: some View {
        @Bindable var client = client
        VStack(alignment: .leading, spacing: 16) {
            Text("This iPhone").font(.headline)
            HStack(spacing: 12) {
                CountTile(value: client.photoCount, label: "Photos", symbol: "photo.fill", tint: .blue)
                CountTile(value: client.videoCount, label: "Videos", symbol: "video.fill", tint: .pink)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Name on your Mac").font(.caption).foregroundStyle(.secondary)
                TextField("iPhone", text: $client.deviceName)
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .submitLabel(.done)
            }
        }
        .card()
    }
}

struct CountTile: View {
    let value: Int
    let label: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(value.formatted())
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct OvernightCard: View {
    @Environment(BackupClient.self) private var client

    var body: some View {
        @Bindable var client = client
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $client.overnightBackup) {
                Label {
                    Text("Back up overnight").font(.headline)
                } icon: {
                    Image(systemName: "moon.stars.fill").foregroundStyle(.indigo)
                }
            }
            .tint(.indigo)
            Text("While your iPhone is charging and on Wi-Fi, usually at night. iOS chooses the exact time. Don't swipe Photo Backup away in the app switcher, or iOS won't run it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if client.overnightBackup {
                Label(lastRunText, systemImage: "clock")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var lastRunText: String {
        guard let date = client.lastAutomaticRun else { return "Hasn't run yet" }
        return "Last ran \(date.formatted(.relative(presentation: .named)))"
    }
}

struct MacCard: View {
    @Environment(BackupClient.self) private var client
    @State private var confirmingUnpair = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(client.credential?.serverName ?? "Mac").font(.headline)
                Text("Paired · backs up on the same Wi-Fi")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Unpair", systemImage: "xmark.circle", role: .destructive) { confirmingUnpair = true }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title2).foregroundStyle(.secondary)
            }
        }
        .card()
        .confirmationDialog("Unpair from \(client.credential?.serverName ?? "Mac")?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { client.unpair() }
        } message: {
            Text("Photos already on the Mac stay there. You can pair again anytime.")
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
