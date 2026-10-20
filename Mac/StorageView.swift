import SwiftUI

extension LocationInfo: Identifiable {
    var id: URL { url }
}

/// Where backups live: the current destination, a quick pick of connected drives, and each iPhone's folder.
struct StorageView: View {
    @Environment(BackupServer.self) private var server

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DestinationCard()
                DrivesCard()
                FoldersCard()
            }
            .padding(28)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Storage")
    }
}

private struct DestinationCard: View {
    @Environment(BackupServer.self) private var server

    var body: some View {
        let location = server.location
        let tint: Color = location.isAvailable ? .teal : .orange
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: location.symbol)
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(
                        LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .shadow(color: tint.opacity(0.3), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Backups are saved to").font(.callout).foregroundStyle(.secondary)
                    Text(location.volumeName).font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(location.displayPath)
                        .font(.callout.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(location.kindDescription).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            if location.isAvailable {
                UsageBar(backup: Int64(server.totalBytes), other: server.otherBytesOnVolume ?? 0, total: location.totalBytes ?? 0)
            } else {
                Label("“\(location.volumeName)” isn't connected. iPhones are told to try again later, and backups resume as soon as you plug it in.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 10) {
                Button {
                    server.chooseLocation()
                } label: {
                    Label("Change Location…", systemImage: "folder.badge.gearshape")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(server.isBackingUp)

                if location.isAvailable {
                    Button("Show in Finder") { server.revealInFinder() }
                        .controlSize(.large)
                }
                Spacer()
                if server.isBackingUp {
                    Label("Available after the current backup", systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .card(padding: 24)
    }
}

/// Photo Backup's share of the disk, everything else, and free space.
private struct UsageBar: View {
    let backup: Int64
    let other: Int64
    let total: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let scale = total > 0 ? width / CGFloat(total) : 0
                HStack(spacing: 2) {
                    if backup > 0 {
                        Rectangle().fill(.blue.gradient).frame(width: max(4, CGFloat(backup) * scale))
                    }
                    Rectangle().fill(.gray.opacity(0.45)).frame(width: max(0, CGFloat(other) * scale))
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(height: 14)
            .clipShape(Capsule())

            HStack(spacing: 18) {
                legend(.blue, "Photo Backup", backup)
                legend(.gray.opacity(0.6), "Other", other)
                legend(Color.secondary.opacity(0.25), "Free", max(0, total - backup - other))
                Spacer()
                Text("\(total.formatted(.byteCount(style: .file))) total")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func legend(_ color: Color, _ label: String, _ bytes: Int64) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
            Text(bytes.formatted(.byteCount(style: .file))).fontWeight(.medium)
        }
        .font(.caption)
    }
}

/// One-click starting points: this Mac's Pictures folder and every connected external or network drive.
private struct DrivesCard: View {
    @Environment(BackupServer.self) private var server

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Choose a drive", symbol: "externaldrive.badge.plus")
            Text("Pick a drive, then choose or create a folder on it. An external drive is a good way to keep backups off your Mac's own disk.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                DriveTile(
                    name: "This Mac", detail: "~/Pictures/Photo Backup", symbol: "laptopcomputer",
                    isCurrent: server.isUsingDefaultLocation, enabled: !server.isBackingUp
                ) {
                    server.useDefaultLocation()
                }
                ForEach(server.drives) { drive in
                    DriveTile(
                        name: drive.volumeName,
                        detail: drive.availableBytes.map { "\($0.formatted(.byteCount(style: .file))) free" } ?? drive.kindDescription,
                        symbol: drive.symbol,
                        isCurrent: !server.isUsingDefaultLocation && server.location.url.path.hasPrefix(drive.url.path),
                        enabled: !server.isBackingUp
                    ) {
                        server.chooseLocation(startingAt: drive.url)
                    }
                }
            }

            if server.drives.isEmpty {
                Label("Connect an external drive and it shows up here.", systemImage: "cable.connector")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .card()
    }
}

private struct DriveTile: View {
    let name: String
    let detail: String
    let symbol: String
    let isCurrent: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(isCurrent ? .white : .teal)
                    .frame(width: 42, height: 42)
                    .background(isCurrent ? AnyShapeStyle(Color.teal.gradient) : AnyShapeStyle(Color.teal.opacity(0.12)),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal)
                }
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hovering && enabled ? Color.primary.opacity(0.05) : Color.primary.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isCurrent ? Color.teal.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: isCurrent ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled || isCurrent)
        .onHover { hovering = $0 }
        .help(isCurrent ? "Backups go here now" : "Back up to \(name)")
    }
}

/// Each iPhone's folder under the current location.
private struct FoldersCard: View {
    @Environment(BackupServer.self) private var server

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Folders", symbol: "folder")
            if server.devices.isEmpty {
                Text("Each iPhone you pair gets its own folder here.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        Text("iPhone"); Text("Folder"); Text("Items").gridColumnAlignment(.trailing); Text("Size").gridColumnAlignment(.trailing); Text("")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(server.devices) { device in
                        let summary = server.summaries[device.id]
                        GridRow {
                            Label(device.name, systemImage: "iphone").lineLimit(1)
                            Text(device.folder).foregroundStyle(.secondary).lineLimit(1)
                            Text((summary?.assetCount ?? 0).formatted()).monospacedDigit()
                            Text((summary?.totalBytes ?? 0).bytes).monospacedDigit()
                            Button {
                                server.revealInFinder(server.folderURL(for: device))
                            } label: {
                                Image(systemName: "arrow.right.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(!server.location.isAvailable)
                            .help("Show in Finder")
                        }
                    }
                }
            }
            Text("Changing the location starts new backups there. Existing backups stay where they are; move them in Finder if you like, and Photo Backup picks them up from the new place.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }
}
