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
