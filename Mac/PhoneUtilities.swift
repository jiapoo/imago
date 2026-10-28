import ImagoKit
import SwiftUI
import UserNotifications

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

/// Tells the user, in Notification Center, when an iPhone answered differently from what was asked
/// here, or photos were deleted on an iPhone: things Imago wants a decision about.
enum MacNotifications {
    static func requestPermission() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    /// The iPhone turned down changes asked for here.
    static func declined(_ changes: [LibraryChange], on phone: String) {
        post(id: "declined-\(phone)",
             title: changes.count == 1 ? "\(phone) said no to a change" : "\(phone) said no to \(changes.count) changes",
             body: changes.prefix(3).map(\.summary).joined(separator: " · ") + ". Open Imago to decide what to keep.")
    }

    /// Photos and videos were deleted on the iPhone since its last backup.
    static func deletedOnPhone(_ count: Int, on phone: String) {
        post(id: "deleted-\(phone)",
             title: count == 1 ? "1 item was deleted on \(phone)" : "\(count) items were deleted on \(phone)",
             body: "The backups are still on your Mac. Open Imago to delete them here too, keep them, or put them back on \(phone).")
    }

    private static func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

// MARK: - Decisions

/// What the iPhones answered that needs a decision here: changes an iPhone said no to, and photos
/// deleted on an iPhone whose backups are still here. On Home (every iPhone) and on an iPhone's page.
struct DecisionsCard: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    @Environment(FileHistory.self) private var history
    let devices: [PairedDevice]
    /// Opens an iPhone's Deleted on iPhone page.
    var openDeleted: (PairedDevice) -> Void

    var body: some View {
        let ids = Set(devices.map(\.id))
        let declines = library.declines.filter { ids.contains($0.device.id) }
        let deleted = devices.compactMap { device -> (PairedDevice, [MediaItem])? in
            let items = library.deletedOnPhone(device.id).filter { !library.restoring.contains($0.id) }
            return items.isEmpty ? nil : (device, items)
        }
        if !declines.isEmpty || !deleted.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Label("Needs your answer", systemImage: "questionmark.bubble")
                    .font(.headline)
                    .padding(.bottom, 10)
                ForEach(declines) { decline in
                    Divider()
                    declineRow(decline)
                }
                ForEach(deleted, id: \.0.id) { device, items in
                    Divider()
                    deletedRow(device, items)
                }
            }
            .modernCard(padding: 18)
        }
    }

    // MARK: Rows

    private func declineRow(_ decline: MediaLibrary.Decline) -> some View {
        let phone = decline.device.name
        let isDelete = decline.change.action == .delete
        return row(
            device: decline.device, symbol: decline.change.symbol,
            title: "\(phone) said no: \(decline.change.summary.lowercasedFirst)",
            detail: isDelete
                ? "They're still on \(phone); their backups are in Recently Deleted on this Mac. Keep them here too, or ask \(phone) once more."
                : "Ask \(phone) once more, or leave it as it is."
                    + (decline.change.isAskedAgain ? " This was the second time it was asked." : "")
        ) {
            if isDelete {
                Button("Keep Here Too") { Task { history.record(await library.keepHereToo(decline, server: server)) } }
                    .buttonStyle(.borderedProminent)
                    .help("Put the backups back where they were: the photos stay on \(phone) and here")
                Menu("More") {
                    Button("Ask \(phone) Again") { Task { await library.askAgain(decline, server: server) } }
                    Button("Leave in Recently Deleted") { Task { await library.leaveAsIs(decline, server: server) } }
                }
                .fixedSize()
            } else {
                Button("Ask Again") { Task { await library.askAgain(decline, server: server) } }
                    .disabled(decline.change.isAskedAgain)
                Button("OK") { Task { await library.leaveAsIs(decline, server: server) } }
            }
        }
    }

    private func deletedRow(_ device: PairedDevice, _ items: [MediaItem]) -> some View {
        row(
            device: device, symbol: "iphone.slash",
            title: items.count == 1 ? "1 item was deleted on \(device.name)" : "\(items.count.formatted()) items were deleted on \(device.name)",
            detail: "\(items.reduce(0) { $0 + $1.bytes }.bytes) backed up here. "
                + (server.trashDays > 0 ? "Unless you decide, they move to Recently Deleted after \(server.trashDays) days." : "They stay until you decide.")
        ) {
            Button("Review") { openDeleted(device) }
            Menu("Decide") {
                Button("Delete Here Too") { Task { history.record(await library.trash(items, server: server)) } }
                Button("Keep the Backups") { Task { history.record(await library.keepBackups(items, server: server)) } }
                Button("Put Back on \(device.name)") { Task { history.record(await library.putBackOnPhone(items, server: server)) } }
            }
            .fixedSize()
        }
    }

    private func row<Actions: View>(device: PairedDevice, symbol: String, title: String, detail: String,
                                    @ViewBuilder actions: () -> Actions) -> some View {
        let color = server.color(of: device.id)
        return HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { actions() }
                .controlSize(.large)
        }
        .padding(.vertical, 12)
    }
}

private extension String {
    /// "Delete 3 items" → "delete 3 items", after "said no:".
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

