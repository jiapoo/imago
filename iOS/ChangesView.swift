import Photos
import ImagoKit
import SwiftUI

/// Shown when the Mac has asked for changes to this iPhone's library.
struct MacChangesCard: View {
    @Environment(BackupClient.self) private var client
    @State private var reviewing = false

    var body: some View {
        let changes = client.macChanges
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer.and.arrow.down")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(client.credential?.serverName ?? "Your Mac") suggests \(changes.count) \(changes.count == 1 ? "change" : "changes")")
                        .font(.headline)
                    if let bytes = freed(changes) {
                        Text("Frees about \(bytes.formatted(.byteCount(style: .file)))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(changes.prefix(3)) { change in
                Label(change.summary, systemImage: change.symbol)
                    .font(.subheadline)
            }
            if changes.count > 3 {
                Text("and \(changes.count - 3) more").font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                reviewing = true
            } label: {
                Text("Review").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.orange)
        }
        .card()
        .sheet(isPresented: $reviewing) { ChangesReviewSheet() }
    }

    private func freed(_ changes: [LibraryChange]) -> UInt64? {
        let total = changes.compactMap(\.bytes).reduce(0, +)
        return total > 0 ? total : nil
    }
}

/// Every change with a preview; the user picks which to make.
struct ChangesReviewSheet: View {
    @Environment(BackupClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var approved: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(client.macChanges) { change in
                        ChangeRow(change: change, isOn: Binding(
                            get: { approved.contains(change.id) },
                            set: { if $0 { approved.insert(change.id) } else { approved.remove(change.id) } }
                        ))
                    }
                } footer: {
                    Text("Changes you turn off are declined, and your Mac is told at the next backup.")
                }

                if client.macChanges.contains(where: { $0.action == .delete }) {
                    Section {
                        Label {
                            Text("Deleted items are already backed up on your Mac. They go to **Recently Deleted** for 30 days. If iCloud Photos is on, they're also removed from your other devices.")
                        } icon: {
                            Image(systemName: "info.circle").foregroundStyle(.orange)
                        }
                        .font(.footnote)
                    }
                }
            }
            .navigationTitle("Changes from \(client.credential?.serverName ?? "Mac")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        apply()
                    } label: {
                        Group {
                            if client.isApplyingChanges {
                                ProgressView().tint(.white)
                            } else {
                                Text(approved.isEmpty ? "Decline All" : "Apply \(approved.count) of \(client.macChanges.count)")
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(client.isApplyingChanges || client.macChanges.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .onAppear { approved = Set(client.macChanges.map(\.id)) }
            .onChange(of: client.macChanges) { _, changes in
                if changes.isEmpty { dismiss() }
            }
        }
    }

    private func apply() {
        let changes = client.macChanges
        Task {
            await client.review(
                approve: changes.filter { approved.contains($0.id) },
                decline: changes.filter { !approved.contains($0.id) }
            )
        }
    }
}

private struct ChangeRow: View {
    let change: LibraryChange
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isOn) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.summary).font(.body.weight(.medium))
                        if let bytes = change.bytes {
                            Text("About \(bytes.formatted(.byteCount(style: .file)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: change.symbol).foregroundStyle(change.action == .delete ? .red : .accentColor)
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(change.assetIDs.prefix(12), id: \.self) { id in
                        AssetThumbnail(assetID: id)
                    }
                    if change.assetIDs.count > 12 {
                        Text("+\(change.assetIDs.count - 12)")
                            .font(.caption.weight(.semibold))
                            .frame(width: 56, height: 56)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.vertical, 4)
    }
}

private struct AssetThumbnail: View {
    let assetID: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color(.tertiarySystemFill)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: assetID) { image = await Self.load(assetID) }
    }

    private static func load(_ id: String) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat   // exactly one callback
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 168, height: 168), contentMode: .aspectFill, options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
