import AppKit
import ImagoKit
import SwiftUI
import UniformTypeIdentifiers

/// What's being dragged out of a grid: the whole selection when the dragged item is part of it.
/// A drag of one tile is SwiftUI's (`onDrag`) and carries one file URL; a drop looks here for the
/// rest. A drag of several selected tiles is AppKit's, from `SelectionDrag`, and carries them all.
@MainActor
enum DragSession {
    static var urls: [URL] = []

    /// For a grid tile's `onDrag`: these files, of which the drag carries the first.
    static func begin(_ urls: [URL]) -> NSItemProvider {
        self.urls = urls
        return urls.first.map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider()
    }
}

/// Drags several selected tiles at once, so Finder gets every file: SwiftUI's `onDrag` carries
/// only one. A press on a selected tile, with more than one selected, is taken before SwiftUI
/// sees the drag, and dragged from AppKit. SwiftUI never starts a drag of its own for it: one
/// started alongside never ends, and SwiftUI drags nothing after that.
@MainActor
enum SelectionDrag {
    /// Each grid on screen: the files to drag from a press at a point in its content (its scroll
    /// view's coordinates), or nil when the press isn't on a selection of several.
    private static var grids: [UUID: (CGPoint) -> [URL]?] = [:]
    private static var monitor: Any?
    /// The press being watched, when it's on a selection of several.
    private static var pressed: (event: NSEvent, urls: [URL])?

    static func register(_ id: UUID, files: @escaping (CGPoint) -> [URL]?) {
        grids[id] = files
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
                handle(event)
            }
        }
    }

    static func unregister(_ id: UUID) { grids[id] = nil }

    private static func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            pressed = nil
            // ⌘ and ⇧ change the selection; a plain press drags it.
            guard event.modifierFlags.intersection([.command, .shift, .control]).isEmpty,
                  let point = contentPoint(of: event),
                  let urls = grids.values.lazy.compactMap({ $0(point) }).first, urls.count > 1 else { return event }
            pressed = (event, urls)
            return event
        case .leftMouseDragged:
            guard let (down, urls) = pressed else { return event }
            let moved = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
            // Too small to be a drag yet: SwiftUI mustn't see it either, or it starts its own.
            guard moved > 3 else { return nil }
            pressed = nil
            start(urls, with: event)
            return nil
        default:
            pressed = nil
            return event
        }
    }

    /// Where a press is in the content of the scroll view it's in.
    private static func contentPoint(of event: NSEvent) -> CGPoint? {
        guard let contentView = event.window?.contentView,
              let clip = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil))?.enclosingScrollView?.contentView,
              clip.isFlipped else { return nil }
        return clip.convert(event.locationInWindow, from: nil)
    }

    private static func start(_ urls: [URL], with event: NSEvent) {
        guard let view = event.window?.contentView else { return }
        DragSession.urls = urls
        let point = view.convert(event.locationInWindow, from: nil)
        let items = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = NSWorkspace.shared.icon(forFile: url.path)
            image.size = NSSize(width: 64, height: 64)
            // A small fan, as Finder draws several files.
            let offset = CGFloat(min(index, 4)) * 6
            item.setDraggingFrame(NSRect(x: point.x - 32 + offset, y: point.y - 32 - offset, width: 64, height: 64), contents: image)
            return item
        }
        let session = view.beginDraggingSession(with: items, event: event, source: FileDragSource.shared)
        session.draggingFormation = .pile
    }
}

/// Lets a grid's selected tiles be dragged together (see `SelectionDrag`).
private struct DragsSelection: ViewModifier {
    let files: (CGPoint) -> [URL]?
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { SelectionDrag.register(id, files: files) }
            .onDisappear { SelectionDrag.unregister(id) }
    }
}

extension View {
    /// On a grid: dragging a selected tile drags `selection`'s files when several are selected.
    /// `tiles` are the tiles' frames in the grid's content.
    func dragsSelection(_ tiles: TileFrames, selection: @escaping () -> Set<String>,
                        files: @escaping (Set<String>) -> [URL]) -> some View {
        modifier(DragsSelection { point in
            let selection = selection()
            guard selection.count > 1,
                  tiles.frames.contains(where: { selection.contains($0.key) && $0.value.contains(point) }) else { return nil }
            return files(selection)
        })
    }

    /// Takes the files dropped here, every one: `dropDestination(for: URL.self)` hands over only the
    /// first of several dragged from Finder.
    func dropsFiles(_ action: @escaping @MainActor ([URL]) -> Bool,
                    isTargeted: ((Bool) -> Void)? = nil) -> some View {
        onDrop(of: [.fileURL], isTargeted: isTargeted.map { set in Binding(get: { false }, set: set) }) { providers in
            Task { @MainActor in _ = action(await GridKeys.fileURLs(from: providers)) }
            return true
        }
    }
}

/// The source of a drag of several files: copies to other apps; here, the drop decides.
@MainActor
private final class FileDragSource: NSObject, NSDraggingSource {
    static let shared = FileDragSource()

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : [.copy, .move, .generic]
    }
}

/// What putting photos and videos into a folder does, chosen in the toolbar.
/// "Send to 007", or "Move to 007" for another iPhone's photos with Move on (see `MediaLibrary.send`).
func sendLabel(_ items: [MediaItem], _ device: PairedDevice) -> String {
    let moving = TransferMode.current == .move && items.contains { $0.deviceID != nil && $0.deviceID != device.id }
    return (moving ? "Move to " : "Send to ") + device.name
}

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

/// What to do with files that are already in the folder, exactly the same.
enum DuplicateChoice {
    /// Leave them out; the rest go ahead.
    case skip
    /// Copy or move them anyway, with a numbered name.
    case keepBoth
    /// Do nothing.
    case cancel
}

/// Files about to go into a folder that already holds identical ones, waiting for the user's answer.
struct DuplicateQuestion: Identifiable {
    let id = UUID()
    var folder: String
    var duplicates: Int
    var total: Int
    var isMove: Bool
    fileprivate var answer: CheckedContinuation<DuplicateChoice, Never>
}

extension MediaLibrary {
    /// Asks what to do about files the folder already has, and waits for the answer.
    func ask(_ duplicates: Int, of total: Int, in folder: String, isMove: Bool) async -> DuplicateChoice {
        await withCheckedContinuation { answer in
            duplicateQuestion = DuplicateQuestion(folder: folder, duplicates: duplicates, total: total, isMove: isMove, answer: answer)
        }
    }

    /// The user's answer; also cancels when the question is dismissed.
    func answerDuplicates(_ choice: DuplicateChoice) {
        guard let question = duplicateQuestion else { return }
        duplicateQuestion = nil
        question.answer.resume(returning: choice)
    }

    /// The files among `files` that `folder` already has, exactly the same: a file there of the same
    /// size, then the same content.
    func identicalFiles(_ files: [URL], inFolder path: String, server: BackupServer) async -> Set<URL> {
        let folder = path.isEmpty ? server.foldersURL : server.foldersURL.appending(path: path, directoryHint: .isDirectory)
        let present: [(url: URL, size: Int)] = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []).compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true,
                  let size = values.fileSize else { return nil }
            return (url, size)
        }
        let bySize = Dictionary(grouping: present, by: \.size)
        let candidates = files.filter { file in
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
            return bySize[size] != nil && file.deletingLastPathComponent().lexicallyStandardized != folder.lexicallyStandardized
        }
        guard !candidates.isEmpty else { return [] }
        activity = Activity(title: "Checking for duplicates", done: 0, total: candidates.count)
        defer { activity = nil }
        var identical: Set<URL> = []
        for file in candidates {
            activity?.detail = file.lastPathComponent
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            let others = bySize[size]?.map(\.url) ?? []
            let same = await Task.detached(priority: .userInitiated) {
                guard let mine = try? FileHasher.sha256(of: file) else { return false }
                return others.contains { (try? FileHasher.sha256(of: $0)) == mine }
            }.value
            if same { identical.insert(file) }
            activity?.done += 1
        }
        return identical
    }

    /// Puts items into a folder the way the toolbar says: copies, or moves and removes them from their
    /// iPhone. Asks first when the folder already has identical files. Records each step for undo.
    func transfer(_ items: [MediaItem], toFolder path: String, server: BackupServer, history: FileHistory) async {
        var items = items
        let identical = await identicalFiles(items.map(\.url), inFolder: path, server: server)
        if !identical.isEmpty {
            switch await ask(identical.count, of: items.count, in: path, isMove: TransferMode.current == .move) {
            case .cancel: return
            case .skip: items.removeAll { identical.contains($0.url) }
            case .keepBoth: break
            }
            guard !items.isEmpty else { return }
        }
        switch TransferMode.current {
        case .copy:
            history.record(await copy(items, toFolder: path, server: server))
        case .move:
            // One step: ⌘Z takes the iPhone's deletion back and returns the files together.
            let fromPhone = removable(items)
            let moved = await move(items, to: .folder(path), server: server)
            // Only what's now in the folder: the iPhone keeps anything that didn't move.
            let arrived = Set(self.items.filter { $0.folder == path }.map(\.id))
            let leaving = fromPhone.filter { arrived.contains($0.id) }
            let removed = leaving.isEmpty ? nil : await removeFromPhone(leaving, server: server)
            let name = "Move to “\((path as NSString).lastPathComponent)”"
            history.record(FileHistory.combine(name, [moved, removed]))
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
        let dropped = droppedItems(urls)
        let known = Set(dropped.map { $0.url.lexicallyStandardized })
        // Ones already there stay put (a folder's own items dropped back on it).
        let moving = dropped.filter { self.place(of: $0) != place }
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
                var files = outside
                let identical = await identicalFiles(files, inFolder: path, server: server)
                if !identical.isEmpty {
                    switch await ask(identical.count, of: files.count, in: path, isMove: false) {
                    case .cancel: return
                    case .skip: files.removeAll { identical.contains($0) }
                    case .keepBoth: break
                    }
                }
                if !files.isEmpty { history.record(await copyIn(files, to: path, server: server)) }
            }
        }
        return true
    }

    /// Adds items to an iPhone's Photos library: Send to iPhone, or a drop on it. With Move, what came
    /// from another iPhone is deleted there, and its backup goes to Recently Deleted: the iPhone it went
    /// to has its own copy. Returns the step that takes it all back.
    func send(_ items: [MediaItem], to device: PairedDevice, server: BackupServer) async -> FileHistory.Step? {
        let items = items.filter { $0.deviceID != device.id }
        guard !items.isEmpty else { return nil }
        let isMove = TransferMode.current == .move
        let (ids, copies) = await server.send(items, to: device)
        guard !ids.isEmpty else { return nil }
        let name = (isMove ? "Move to " : "Send to ") + device.name
        // Undo takes back what hasn't gone yet; what the iPhone added stays there.
        let sent = FileHistory.Step(name: name) {
            server.withdrawRestore(Set(ids), on: device, removing: copies)
            return nil
        }
        let leaving = isMove ? items.filter { $0.deviceID != nil } : []
        let removed = leaving.isEmpty ? nil : await deleteFromPhoneAndHere(leaving, server: server)
        return FileHistory.combine(name, [sent, removed])
    }

    /// A drop on an iPhone: its own items move back into its folder; everything else is sent to it
    /// (copied, or moved per Copy | Move).
    func drop(_ urls: [URL], onto device: PairedDevice, server: BackupServer, history: FileHistory) -> Bool {
        let trashed = Set(trash.map(\.item.id))
        let dropped = droppedItems(urls).filter { !trashed.contains($0.id) }
        let own = dropped.filter { $0.deviceID == device.id && place(of: $0) != .phoneFolder }
        let others = dropped.filter { $0.deviceID != device.id }
        guard !own.isEmpty || !others.isEmpty else { return false }
        DragSession.urls = []
        Task {
            if !own.isEmpty { history.record(await move(own, to: .phoneFolder, server: server)) }
            if !others.isEmpty { history.record(await send(others, to: device, server: server)) }
        }
        return true
    }

    /// Copies files from outside the library into a folder. Returns the step that removes the copies.
    func copyIn(_ files: [URL], to path: String, server: BackupServer) async -> FileHistory.Step? {
        await copyFiles(files, to: path, server: server).undo
    }

    /// Files an edited copy of `item` beside it (in its folder, or its iPhone's own dated folder), in
    /// the background, as Photos does: a backup drive can take seconds to write a big video, and
    /// meanwhile the copy can be watched where the editor made it (`staged`, on the Mac's own disk).
    /// `written` gives the step that removes the copy once it's on the drive, or nil if it couldn't be.
    func saveEditedCopy(_ copy: URL, of item: MediaItem, server: BackupServer) -> (place: String, staged: URL, written: Task<FileHistory.Step?, Never>)? {
        let path = editedCopyFolder(for: item, server: server)
        // Out of the editor's temporary folder, which goes as soon as the save returns. The same disk,
        // so it's a rename.
        let staged = Self.stagingFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: copy.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: copy, to: staged)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
        let written = Task { await copyFiles([staged], to: path, server: server, quietly: true).undo }
        return (path.isEmpty ? server.location.url.lastPathComponent : FolderMark.name(path), staged, written)
    }

    /// Edited copies waiting to be written to the drive, and shown from here meanwhile. Emptied at launch.
    nonisolated static var stagingFolder: URL {
        FileManager.default.temporaryDirectory.appending(path: "Edited copies", directoryHint: .isDirectory)
    }

    /// `copyIn`, and where the copies went. `quietly`: no progress card (it would cover the viewer).
    private func copyFiles(_ files: [URL], to path: String, server: BackupServer, quietly: Bool = false) async -> (undo: FileHistory.Step?, copies: [URL]) {
        let folder = path.isEmpty ? server.foldersURL : server.foldersURL.appending(path: path, directoryHint: .isDirectory)
        if !quietly { activity = Activity(title: "Copying to “\((path as NSString).lastPathComponent)”", done: 0, total: files.count) }
        beginWork()
        defer {
            activity = nil
            endWork()
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var copies: [URL] = []
        for (index, file) in files.enumerated() {
            var target = folder.appending(path: file.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = URL(filePath: LibraryLayout.numbered(folder.appending(path: file.lastPathComponent).path, n))
                n += 1
            }
            activity?.detail = file.lastPathComponent
            activity?.bytes = nil
            let destination = target
            let copied = await Task.detached(priority: .userInitiated) { [weak self] in
                (try? Self.copyFile(file, to: destination) { done, total in
                    Task { @MainActor in self?.activity?.bytes = (done, total) }
                }) != nil
            }.value
            if copied { copies.append(target) }
            activity?.done = index + 1
        }
        // The copies show at once, without reading the library again.
        showCopies(copies, server: server)
        guard !copies.isEmpty else { return (nil, []) }
        let undo = FileHistory.Step(name: copies.count == 1 ? "Copy" : "Copy \(copies.count) Items") { [weak self] in
            for copy in copies { try? FileManager.default.removeItem(at: copy) }
            self?.hideRemoved(copies, server: server)
            return FileHistory.Step(name: "Copy") { [weak self] in await self?.copyIn(files, to: path, server: server) }
        }
        return (undo, copies.map(\.lexicallyStandardized))
    }

    /// Copies one file. A big one goes in 8 MB pieces with `progress` (bytes so far, size), so a long
    /// copy shows how far it's got; a small one in one go. The copy keeps the original's dates.
    nonisolated static func copyFile(_ source: URL, to destination: URL, progress: @escaping @Sendable (UInt64, UInt64) -> Void) throws {
        let size = UInt64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size > 64_000_000 else {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var copied: UInt64 = 0
            var lastReport = Date.distantPast
            while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                copied += UInt64(chunk.count)
                if Date.now.timeIntervalSince(lastReport) > 0.1 {
                    lastReport = .now
                    progress(copied, size)
                }
            }
            progress(copied, size)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) {
                var dates: [FileAttributeKey: Any] = [:]
                if let created = attributes[.creationDate] as? Date { dates[.creationDate] = created }
                if let modified = attributes[.modificationDate] as? Date { dates[.modificationDate] = modified }
                try? FileManager.default.setAttributes(dates, ofItemAtPath: destination.path)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    nonisolated static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }
}

