import AppKit
import SwiftUI

/// Undo and redo for what Imago does to the library: moves, deletions and restores, new and renamed
/// folders, and changes queued for an iPhone.
///
/// These run on the backup drive in the background, which AppKit's UndoManager doesn't suit: it
/// wants the opposite action registered while the action runs, and an undo's own undo registered
/// before it returns. So each action here returns a `Step` that undoes it, and running a step
/// returns the step that redoes it. Edit › Undo and Redo walk the two stacks.
@MainActor @Observable
final class FileHistory {
    struct Step {
        /// For the menu: "Move to “Tennis”", "Delete 3 Items"…
        let name: String
        /// Undoes (or redoes) the action. Returns the step that reverses this one, nil if it couldn't.
        let run: @MainActor () async -> Step?
    }

    private(set) var undoStack: [Step] = []
    private(set) var redoStack: [Step] = []
    /// An undo or redo is running; another waits for it.
    private(set) var isBusy = false

    var canUndo: Bool { !undoStack.isEmpty && !isBusy }
    var canRedo: Bool { !redoStack.isEmpty && !isBusy }
    var undoTitle: String { undoStack.last.map { "Undo \($0.name)" } ?? "Undo" }
    var redoTitle: String { redoStack.last.map { "Redo \($0.name)" } ?? "Redo" }

    /// Records an action that just happened. A new action ends what could be redone.
    func record(_ step: Step?) {
        guard let step else { return }
        undoStack.append(step)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack = []
    }

    func undo() async {
        guard canUndo, let step = undoStack.popLast() else { return }
        isBusy = true
        defer { isBusy = false }
        if let redo = await step.run() { redoStack.append(redo) }
    }

    func redo() async {
        guard canRedo, let step = redoStack.popLast() else { return }
        isBusy = true
        defer { isBusy = false }
        if let undo = await step.run() { undoStack.append(undo) }
    }
}

/// Edit › Undo and Redo for the library. While typing in a field, they act on the text as usual.
struct FileHistoryCommands: Commands {
    let history: FileHistory

    var body: some Commands {
        // Never disabled: while a text field has the keyboard, ⌘Z must still reach its text.
        CommandGroup(replacing: .undoRedo) {
            Button(history.undoTitle) {
                if Self.isTyping { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { Task { await history.undo() } }
            }
            .keyboardShortcut("z")
            Button(history.redoTitle) {
                if Self.isTyping { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { Task { await history.redo() } }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }

    /// A text field has the keyboard: undo belongs to its text. Checked when the command runs.
    @MainActor private static var isTyping: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }
}
