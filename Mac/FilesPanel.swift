import AppKit
import ImagoKit
import SwiftUI
import UniformTypeIdentifiers

/// What's being dragged out of a grid: the whole selection when the dragged item is part of it.
/// A drag carries one file URL; a drop looks here for the rest.
@MainActor
enum DragSession {
    static var urls: [URL] = []
}

/// What putting photos and videos into a folder does, chosen in the toolbar.
enum TransferMode: String, CaseIterable, Identifiable {
    /// Copies them in; the iPhone and its backup stay as they are. The default.
    case copy
    /// Moves them out of the iPhone's backup into the folder, and asks the iPhone to delete them, once
    /// each is checked against its backup: this frees space on the iPhone.
    case move

    static let key = "transferMode"
    var id: Self { self }

    static var current: TransferMode {
        UserDefaults.standard.string(forKey: key).flatMap(TransferMode.init) ?? .copy
    }
}

extension MediaLibrary {
    /// Puts items into a folder the way the toolbar says: copies, or moves and removes them from their
    /// iPhone. Records each step for undo.
    func transfer(_ items: [MediaItem], toFolder path: String, server: BackupServer, history: FileHistory) async {
        switch TransferMode.current {
        case .copy:
            history.record(await copy(items, toFolder: path, server: server))
        case .move:
            let fromPhone = removable(items)
            history.record(await move(items, to: .folder(path), server: server))
            if !fromPhone.isEmpty { history.record(await removeFromPhone(fromPhone, server: server)) }
        }
    }

    /// What was dropped: the library's items for these files, or the whole dragged selection when
    /// they're part of it.
    func droppedItems(_ urls: [URL]) -> [MediaItem] {
        var wanted = Set(urls.map(\.lexicallyStandardized))
        let dragged = Set(DragSession.urls.map(\.lexicallyStandardized))
        if !wanted.isDisjoint(with: dragged) { wanted.formUnion(dragged) }
        return (items + trash.map(\.item)).filter { wanted.contains($0.url.lexicallyStandardized) }
    }

    /// Handles a drop onto a place. Onto a folder, library items are copied or moved there (the toolbar's
    /// mode); onto an iPhone's folder, its items move back; onto Recently Deleted, they're deleted.
    /// Photos and videos from elsewhere (Finder) are copied into a folder. Returns whether anything was taken.
    func drop(_ urls: [URL], onto place: Place, server: BackupServer, history: FileHistory) -> Bool {
        let moving = droppedItems(urls)
        let known = Set(moving.map { $0.url.lexicallyStandardized })
        let outside = urls.filter { !known.contains($0.lexicallyStandardized) && Self.isMedia($0) && !$0.path.hasPrefix(server.location.url.path) }
        guard !moving.isEmpty || !outside.isEmpty else { return false }
        DragSession.urls = []
        Task {
            if !moving.isEmpty {
                switch place {
                case .folder(let path): await transfer(moving, toFolder: path, server: server, history: history)
                case .phoneFolder, .trash: history.record(await move(moving, to: place, server: server))
                }
            }
            if case .folder(let path) = place, !outside.isEmpty {
                history.record(await copyIn(outside, to: path, server: server))
            }
        }
        return true
    }

    /// Copies files from outside the library into a folder. Returns the step that removes the copies.
    func copyIn(_ files: [URL], to path: String, server: BackupServer) async -> FileHistory.Step? {
        let folder = path.isEmpty ? server.foldersURL : server.foldersURL.appending(path: path, directoryHint: .isDirectory)
        let copies: [URL] = await Task.detached(priority: .userInitiated) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return files.compactMap { file in
                var target = folder.appending(path: file.lastPathComponent)
                var n = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    target = URL(filePath: LibraryLayout.numbered(folder.appending(path: file.lastPathComponent).path, n))
                    n += 1
                }
                return (try? FileManager.default.copyItem(at: file, to: target)) != nil ? target : nil
            }
        }.value
        await load(from: server, force: true)
        guard !copies.isEmpty else { return nil }
        return FileHistory.Step(name: copies.count == 1 ? "Copy" : "Copy \(copies.count) Items") { [weak self] in
            for copy in copies { try? FileManager.default.removeItem(at: copy) }
            await self?.load(from: server, force: true)
            return FileHistory.Step(name: "Copy") { [weak self] in await self?.copyIn(files, to: path, server: server) }
        }
    }

    nonisolated static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }
}

/// The backup drive as Finder shows it, on the right of the window, full height: every folder at its
/// top, by name, each opening to the folders inside. Your folders take photos and videos dropped on
/// them (copied or moved, by the toolbar's Copy | Move); an iPhone's folders take back its own items;
/// Recently Deleted deletes. Click a folder to show it.
struct FilesPanel: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    @Binding var selection: SidebarItem?
    @Binding var isShown: Bool
    @State private var naming: FolderNaming?
    /// Each iPhone folder's year and month folders, read from the drive when the panel opens.
    @State private var phoneFolders: [String: [DriveNode]] = [:]

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(nodes) { node in
                    DriveTreeRow(node: node, naming: $naming)
                }
            } header: {
                Label(server.location.volumeName, systemImage: "externaldrive.fill")
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { naming = .newFolder(moving: [], in: nil) } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .help("New folder at the top of the backup drive")
                .disabled(!server.location.isAvailable)
            }
            ToolbarItem(placement: .primaryAction) { FilesPanelToggle(isShown: $isShown) }
        }
        .folderNameAlert($naming, library: library, server: server) { selection = .folder($0) }
        .task(id: "\(server.catalogRevision)-\(server.devices.count)") { await loadPhoneFolders() }
    }

    /// Everything at the top of the drive, by name, as Finder lists it.
    private var nodes: [DriveNode] {
        var nodes = server.devices.map { device in
            DriveNode(id: "phone:\(device.id)", name: device.folder, kind: .phone(device), count: nil,
                      children: phoneFolders[device.id].flatMap { $0.isEmpty ? nil : $0 })
        }
        nodes += library.folders.map(DriveNode.init(folder:))
        nodes.append(DriveNode(id: "trash", name: (server.trashFolder as NSString).lastPathComponent, kind: .trash,
                               count: library.trash.isEmpty ? nil : library.trash.count, children: nil))
        return nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Year and month folders inside each iPhone's folder: just their names, nothing inside them.
    private func loadPhoneFolders() async {
        let root = server.location.url
        let devices = server.devices
        phoneFolders = await Task.detached(priority: .utility) {
            func directories(_ url: URL) -> [URL] {
                ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }
            var result: [String: [DriveNode]] = [:]
            for device in devices {
                result[device.id] = directories(root.appending(path: device.folder, directoryHint: .isDirectory)).map { year in
                    let months = directories(year).map { month in
                        DriveNode(id: "phone:\(device.id)/\(year.lastPathComponent)/\(month.lastPathComponent)",
                                  name: month.lastPathComponent, kind: .phoneFolder(device), count: nil, children: nil)
                    }
                    return DriveNode(id: "phone:\(device.id)/\(year.lastPathComponent)", name: year.lastPathComponent,
                                     kind: .phoneFolder(device), count: nil, children: months.isEmpty ? nil : months)
                }
            }
            return result
        }.value
    }
}

/// A folder in the panel.
struct DriveNode: Identifiable, Sendable {
    enum Kind: Sendable {
        /// An iPhone's own folder.
        case phone(PairedDevice)
        /// A year or month folder inside an iPhone's folder.
        case phoneFolder(PairedDevice)
        /// One of the user's folders, by path.
        case folder(String)
        case trash
    }

    var id: String
    var name: String
    var kind: Kind
    var count: Int?
    var children: [DriveNode]?

    init(id: String, name: String, kind: Kind, count: Int?, children: [DriveNode]?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.count = count
        self.children = children
    }

    init(folder: MediaLibrary.Folder) {
        self.init(id: "folder:\(folder.path)", name: folder.name, kind: .folder(folder.path),
                  count: folder.count > 0 ? folder.count : nil, children: folder.children?.map(DriveNode.init(folder:)))
    }

    /// Where dropped photos go.
    var place: MediaLibrary.Place {
        switch kind {
        case .phone, .phoneFolder: .phoneFolder
        case .folder(let path): .folder(path)
        case .trash: .trash
        }
    }

    /// What clicking it shows; nil for the folders inside an iPhone's folder.
    var tag: SidebarItem? {
        switch kind {
        case .phone(let device): .manage(device.id)
        case .phoneFolder: nil
        case .folder(let path): .folder(path)
        case .trash: .trash
        }
    }
}

/// A folder row, with the folders inside it. Opens while something is dragged over it.
private struct DriveTreeRow: View {
    let node: DriveNode
    @Binding var naming: FolderNaming?
    @State private var expanded = false

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(children) { child in DriveTreeRow(node: child, naming: $naming) }
            } label: {
                row
            }
            .springLoadingBehavior(.enabled)
        } else {
            row
        }
    }

    @ViewBuilder
    private var row: some View {
        if let tag = node.tag {
            DriveRow(node: node, naming: $naming).tag(tag)
        } else {
            DriveRow(node: node, naming: $naming)
        }
    }
}

/// One folder: its icon and name, and what a drop on it does.
private struct DriveRow: View {
    @Environment(BackupServer.self) private var server
    @Environment(MediaLibrary.self) private var library
    @Environment(FileHistory.self) private var history
    let node: DriveNode
    @Binding var naming: FolderNaming?
    @State private var targeted = false

    var body: some View {
        Label {
            HStack {
                Text(node.name).lineLimit(1)
                Spacer()
                if let count = node.count {
                    Text(count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: targeted ? dropSymbol : symbol)
                .foregroundStyle(.tint)
                .contentTransition(.symbolEffect(.replace))
        }
        .help(help)
        .dropDestination(for: URL.self) { urls, _ in
            library.drop(urls, onto: node.place, server: server, history: history)
        } isTargeted: { targeted = $0 }
        .contextMenu { menu }
    }

    private var symbol: String {
        if case .trash = node.kind { return "trash.fill" }
        return "folder.fill"
    }

    private var dropSymbol: String {
        switch node.kind {
        case .trash: "trash.fill"
        case .phone, .phoneFolder: "iphone.and.arrow.forward"
        case .folder: TransferMode.current == .move ? "folder.fill.badge.minus" : "folder.fill.badge.plus"
        }
    }

    private var help: String {
        switch node.kind {
        case .phone(let device), .phoneFolder(let device): "\(device.name)'s backup. Drop its photos here to move them back into it."
        case .folder: TransferMode.current == .move
            ? "Drop photos here to move them in and remove them from the iPhone"
            : "Drop photos here to copy them in"
        case .trash: "Drop photos here to delete them; Put Back returns them"
        }
    }

    @ViewBuilder
    private var menu: some View {
        switch node.kind {
        case .folder(let path):
            Button("New Folder Inside…") { naming = .newFolder(moving: [], in: path) }
            Button("Rename…") { naming = .rename(path) }
            Button("Show in Finder") { server.revealInFinder(server.foldersURL.appending(path: path)) }
            Divider()
            Button("Delete Folder", role: .destructive) {
                Task { history.record(await library.deleteFolder(path, server: server)) }
            }
            .disabled(node.count != nil || node.children != nil)
        case .phone(let device):
            Button("Show in Finder") { server.revealInFinder(server.folderURL(for: device)) }
        case .phoneFolder(let device):
            Button("Show \(device.name)'s Folder in Finder") { server.revealInFinder(server.folderURL(for: device)) }
        case .trash:
            Button("Show in Finder") { server.revealInFinder(server.trashURL) }
        }
    }
}
