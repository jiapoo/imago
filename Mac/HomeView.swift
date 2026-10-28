import ImagoKit
import SwiftUI

/// Home: how the backups stand, at a glance. A banner in the status's colour, the library's numbers,
/// any backup running now, a card per iPhone, shortcuts into the library, the backup drive, and what
/// happened recently. Every part opens the page it's about.
struct HomeView: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    @Binding var showingAddPhone: Bool
    @Binding var selection: SidebarItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                numbers
                if server.isBackingUp { BackingUpCard() }
                if !server.devices.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                        ForEach(server.devices) { device in
                            PhoneCard(device: device) { selection = .device(device.id) }
                        }
                    }
                }
                ShortcutsCard(selection: $selection)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 22, alignment: .top)], spacing: 22) {
                    DriveCard { selection = .storage }
                    RecentCard()
                }
            }
            .padding(32)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Home")
    }

    // MARK: Hero

    private var hero: some View {
        let health = server.health
        return HStack(spacing: 22) {
            ZStack {
                Circle().fill(.white.opacity(0.18))
                Image(systemName: health.symbol)
                    .font(.system(size: 34, weight: .medium))
                    .symbolEffect(.rotate, options: .repeating, isActive: server.isBackingUp)
            }
            .frame(width: 76, height: 76)
            VStack(alignment: .leading, spacing: 6) {
                Text(health.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(health.subtitle)
                    .font(.body)
                    .opacity(0.9)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if server.devices.isEmpty {
                heroButton("Add iPhone", symbol: "plus") { showingAddPhone = true }
            } else {
                heroButton("Open Library", symbol: "photo.on.rectangle.angled") { selection = .library }
            }
        }
        .foregroundStyle(.white)
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [heroTint, heroTint.mix(with: .black, by: 0.35)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(alignment: .topTrailing) {
                    Circle().fill(.white.opacity(0.10)).frame(width: 260).blur(radius: 40).offset(x: 60, y: -110)
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: heroTint.opacity(0.25), radius: 18, y: 8)
        }
        .animation(.smooth, value: health.title)
    }

    /// The banner's colour: Imago's red when all is well, the status's own otherwise.
    private var heroTint: Color {
        let health = server.health
        return health.tint == .green ? .imago : health.tint == .secondary ? .gray : health.tint
    }

    private func heroButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(.white, in: Capsule())
                .foregroundStyle(heroTint)
        }
        .buttonStyle(.plain)
    }

    // MARK: Numbers

    private var numbers: some View {
        let location = server.location
        let live = server.devices.count { server.liveDevices.contains($0.id) }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
            NumberTile(title: "Photos & videos", value: server.totalAssets.formatted(),
                       detail: server.devices.count == 1 ? "from 1 iPhone" : "from \(server.devices.count) iPhones", symbol: "photo.stack")
            NumberTile(title: "On the backup drive", value: server.totalBytes.bytes,
                       detail: location.volumeName, symbol: "externaldrive")
            NumberTile(title: "Free on the drive", value: location.availableBytes.map { $0.formatted(.byteCount(style: .file)) } ?? "–",
                       detail: location.totalBytes.map { "of \($0.formatted(.byteCount(style: .file)))" }, symbol: "chart.pie")
            NumberTile(title: "Last backup", value: server.lastBackup.map { $0.formatted(.relative(presentation: .named)) } ?? "–",
                       detail: live > 0 ? "Imago open on \(live == 1 ? "1 iPhone" : "\(live) iPhones")" : nil, symbol: "clock")
        }
    }
}

// MARK: - Backing up now

private struct BackingUpCard: View {
    @Environment(BackupServer.self) private var server

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "Backing up now", symbol: "arrow.up.circle")
            ForEach(Array(server.sessions.values).filter { $0.deviceID != nil }) { session in
                let name = server.devices.first { $0.id == session.deviceID }?.name ?? "iPhone"
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(name).font(.headline)
                        Spacer()
                        Text(session.total == 0 ? "Comparing…" : "\(session.received.formatted()) of \(session.total.formatted())")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(session.received), total: Double(max(session.total, 1)))
                        .tint(.imago)
                    if let file = session.currentFile {
                        Text(file).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
        }
        .modernCard()
    }
}

// MARK: - iPhones

/// An iPhone at a glance; opens its page.
private struct PhoneCard: View {
    @Environment(BackupServer.self) private var server
    let device: PairedDevice
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let summary = server.summaries[device.id]
        Button(action: open) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "iphone")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(server.color(of: device.id).ink)
                        .frame(width: 38, height: 38)
                        .background(server.color(of: device.id).gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.headline).lineLimit(1)
                        Text(status(summary)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if server.session(for: device) != nil {
                        ProgressView().controlSize(.small)
                    } else if server.liveDevices.contains(device.id) {
                        Circle().fill(.green).frame(width: 8, height: 8).help("Imago is open on \(device.name)")
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    figure((summary?.assetCount ?? 0).formatted(), "items")
                    figure((summary?.totalBytes ?? 0).bytes, "on the drive")
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(hovering ? 0.14 : 0.06)))
            .shadow(color: .black.opacity(hovering ? 0.08 : 0.04), radius: hovering ? 16 : 12, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func status(_ summary: BackupStore.Summary?) -> String {
        if let session = server.session(for: device) {
            return session.total == 0 ? "Comparing libraries…" : "Backing up \(session.received) of \(session.total)"
        }
        if summary?.isPartial == true { return "Backup not finished" }
        if let last = summary?.lastBackup { return "Backed up \(last.shortRelative)" }
        return "No backup yet"
    }
}

// MARK: - Shortcuts

/// Into the library: everything, the biggest, and what's waiting in Recently Deleted.
private struct ShortcutsCard: View {
    @Environment(MediaLibrary.self) private var library
    @Binding var selection: SidebarItem?

    var body: some View {
        let large = library.items(in: .large)
        HStack(spacing: 12) {
            Shortcut(title: "Library", symbol: "photo.on.rectangle.angled",
                     detail: "\(library.items.count.formatted()) items") { selection = .library }
            Shortcut(title: "Large Files", symbol: "externaldrive.fill.badge.minus",
                     detail: large.isEmpty ? "None" : "\(large.count.formatted()) · \(large.reduce(0) { $0 + $1.bytes }.bytes)") { selection = .large }
            Shortcut(title: "Recently Deleted", symbol: "trash",
                     detail: library.trash.isEmpty ? "Empty" : "\(library.trash.count.formatted()) items") { selection = .trash }
        }
    }
}

private struct Shortcut: View {
    let title: String
    let symbol: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(Color.imago)
                    .frame(width: 34, height: 34)
                    .background(Color.imago.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(hovering ? 0.14 : 0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Drive

private struct DriveCard: View {
    @Environment(BackupServer.self) private var server
    /// Opens Storage, to change the location.
    var manage: () -> Void

    var body: some View {
        let location = server.location
        VStack(alignment: .leading, spacing: 16) {
            CardTitle(title: "Backup drive", symbol: "externaldrive") {
                Button("Change…", action: manage).buttonStyle(.link)
            }
            HStack(spacing: 14) {
                Image(systemName: location.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(location.isAvailable ? Color.imago : .orange)
                    .frame(width: 50, height: 50)
                    .background((location.isAvailable ? Color.imago : .orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.volumeName).font(.title3.weight(.semibold))
                    Text(location.displayPath).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text(location.kindDescription).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            if !location.isAvailable {
                Label("“\(location.volumeName)” isn't connected. Backups resume when you plug it in.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else if let used = location.usedFraction, let free = location.availableBytes, let total = location.totalBytes {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: used)
                        .tint(used > 0.9 ? .red : used > 0.75 ? .orange : .imago)
                    HStack {
                        Text("\(free.formatted(.byteCount(style: .file))) free of \(total.formatted(.byteCount(style: .file)))")
                        Spacer()
                        Button("Show in Finder") { server.revealInFinder() }.buttonStyle(.link)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .modernCard()
    }
}

// MARK: - Recent

private struct RecentCard: View {
    @Environment(BackupServer.self) private var server

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "Recent activity", symbol: "clock.arrow.circlepath")
            if server.log.isEmpty {
                Text("Nothing yet. What happens while Imago is open shows here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(server.log.prefix(7)) { line in
                HStack(spacing: 10) {
                    Image(systemName: line.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(line.text).lineLimit(2)
                    Spacer()
                    Text(line.date, style: .time)
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .font(.callout)
            }
        }
        .modernCard()
    }
}
