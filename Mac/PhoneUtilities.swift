import ImagoKit
import SwiftUI

// The phone browser's tools for freeing space, and the list of changes waiting for the phone.

/// Sets of near-identical items, one per row, the suggested keeper first.
struct GroupsView: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    @Environment(FileHistory.self) private var history
    @Environment(\.phoneSelectMode) private var selectMode
    let model: PhoneLibraryModel
    let device: PairedDevice
    let groups: [Cleanup.Group]
    let explanation: String
    let emptyTitle: String
    @State private var selection: Set<String> = []
    @State private var confirmingDelete = false
    @State private var namingAlbum = false

    private var actions: PhoneActions { PhoneActions(server: server, model: model, device: device, library: library, history: history) }
    private var selected: [PhoneAsset] { groups.flatMap(\.assets).filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            if groups.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "checkmark.circle")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            Text(explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Select All Extras") { selection = Set(groups.flatMap(\.extras).filter(\.isBackedUp).map(\.id)) }
                        }
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(group.keep.metadata.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Undated")
                                        .font(.callout.weight(.medium))
                                    Text("\(group.assets.count) items · \(group.reclaimableBytes.bytes) extra")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                }
                                ScrollView(.horizontal) {
                                    HStack(spacing: 10) {
                                        ForEach([group.keep] + group.extras) { asset in
                                            PhoneTile(asset: asset, url: model.files[asset.id], thumbnailBytes: model.thumbnailBytes[asset.id] ?? 0,
                                                      selected: selection.contains(asset.id),
                                                      waiting: model.waiting.contains(asset.id), badge: asset.id == group.keep.id ? "KEEP" : nil)
                                                .frame(width: 130)
                                                .onTapGesture { selection.formSymmetricDifference([asset.id]) }
                                        }
                                    }
                                }
                                .scrollIndicators(.never)
                            }
                            .card(padding: 14)
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 76)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !selected.isEmpty {
                PhoneSelectionBar(actions: actions, selected: selected, confirmingDelete: $confirmingDelete,
                                  namingAlbum: $namingAlbum, clear: { selection = [] })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: selection.isEmpty)
        .modifier(PhoneDialogs(actions: actions, selected: selected, confirmingDelete: $confirmingDelete,
                               namingAlbum: $namingAlbum, done: { selection = [] }))
        .onChange(of: selectMode) { old, new in
            if case .on(let request) = new, case .on(let before) = old, request != before {
                selection = Set(groups.flatMap(\.assets).map(\.id))
            }
            if new == .off { selection = [] }
        }
    }
}

struct SimilarView: View {
    let model: PhoneLibraryModel
    let device: PairedDevice

    var body: some View {
        if let progress = model.similarProgress {
            VStack(spacing: 14) {
                ProgressView(value: progress).frame(width: 280)
                Text("Comparing photos taken close together…").foregroundStyle(.secondary)
                Button("Stop") { model.cancelSimilar() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let similar = model.similar {
            GroupsView(model: model, device: device, groups: model.bursts + similar,
                       explanation: "Shots of the same moment, and bursts. Keep marks the favorite, or the best-looking one by the Mac's photo analysis.",
                       emptyTitle: "No similar shots")
        } else {
            VStack(spacing: 14) {
                Image(systemName: "square.stack.3d.down.right").font(.system(size: 44)).foregroundStyle(.tint)
                Text("Find similar shots").font(.title2.bold())
                Text("The Mac compares photos taken within a minute of each other, using the backed-up copies. Nothing leaves this Mac.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
                Button("Scan \(model.backedUpCount.formatted()) Photos") { model.findSimilar() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                if !model.bursts.isEmpty {
                    Text("\(model.bursts.count) bursts are already listed once you scan.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct QueueView: View {
    @Environment(BackupServer.self) private var server
    let model: PhoneLibraryModel
    let device: PairedDevice

    var body: some View {
        List {
            Section {
                if model.queue.pending.isEmpty {
                    Text("Nothing waiting.").foregroundStyle(.secondary)
                }
                ForEach(model.queue.pending) { change in
                    HStack(spacing: 12) {
                        Image(systemName: change.symbol).foregroundStyle(change.action == .delete ? .red : .accentColor).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.summary)
                            Text("Queued \(change.createdAt.shortRelative)" + (change.bytes.map { " · frees about \($0.bytes)" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") { server.cancel(change, on: device) }
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text("Waiting for \(device.name)")
            } footer: {
                Text(server.liveDevices.contains(device.id)
                     ? "Imago is open on \(device.name), so these have reached it. Each is done once you approve it there, or right away if it's set to apply changes from this Mac."
                     : "These go to \(device.name) when you open Imago on it, or at its next backup. Nothing changes there until you approve it.")
            }

            if !model.queue.done.isEmpty {
                Section("Done") {
                    ForEach(model.queue.done) { done in
                        HStack(spacing: 12) {
                            Image(systemName: done.report.outcome == .applied ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(done.report.outcome == .applied ? .green : .secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(done.change.summary)
                                Text(outcome(done.report)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func outcome(_ report: ChangeReport) -> String {
        let when = report.date.shortRelative
        return switch report.outcome {
        case .applied: "Done on the iPhone \(when)"
        case .declined: "Declined on the iPhone \(when)"
        case .failed: "Couldn't be done \(when)" + (report.detail.map { ": \($0)" } ?? "")
        }
    }
}
