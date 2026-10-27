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

    /// Copies files from outside the library into a folder. Returns the step that removes the copies.
    func copyIn(_ files: [URL], to path: String, server: BackupServer) async -> FileHistory.Step? {
        let folder = path.isEmpty ? server.foldersURL : server.foldersURL.appending(path: path, directoryHint: .isDirectory)
        activity = Activity(title: "Copying to “\((path as NSString).lastPathComponent)”", done: 0, total: files.count)
        defer { activity = nil }
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
        await load(from: server, force: true)
        guard !copies.isEmpty else { return nil }
        return FileHistory.Step(name: copies.count == 1 ? "Copy" : "Copy \(copies.count) Items") { [weak self] in
            for copy in copies { try? FileManager.default.removeItem(at: copy) }
            await self?.load(from: server, force: true)
            return FileHistory.Step(name: "Copy") { [weak self] in await self?.copyIn(files, to: path, server: server) }
        }
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
