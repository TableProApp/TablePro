//
//  EditorEventRouter.swift
//  TablePro
//

@preconcurrency import AppKit
import TableProEditorKit
import TableProTextEngine

@MainActor
internal final class EditorEventRouter {
    internal static let shared = EditorEventRouter()

    private struct EditorRef {
        weak var coordinator: SQLEditorCoordinator?
        weak var textView: TextView?
        var windowObserver: NSObjectProtocol?
        var needsFirstResponderCheck = false
    }

    private var editors: [ObjectIdentifier: EditorRef] = [:]

    private init() {}

    // MARK: - Registration

    internal func register(_ coordinator: SQLEditorCoordinator, textView: TextView) {
        let key = ObjectIdentifier(coordinator)
        editors[key] = EditorRef(coordinator: coordinator, textView: textView)

        if textView.window != nil {
            installWindowObserver(for: key)
        } else {
            Task { [weak self] in
                guard let self, self.editors[key]?.windowObserver == nil else { return }
                self.installWindowObserver(for: key)
            }
        }
    }

    internal func unregister(_ coordinator: SQLEditorCoordinator) {
        let key = ObjectIdentifier(coordinator)
        if let observer = editors[key]?.windowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        editors.removeValue(forKey: key)
        purgeStaleEntries()
    }

    // MARK: - Per-Window Observer

    private func installWindowObserver(for key: ObjectIdentifier) {
        guard editors[key]?.windowObserver == nil,
              let textView = editors[key]?.textView,
              let window = textView.window else { return }

        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard var ref = self.editors[key], !ref.needsFirstResponderCheck else { return }
                ref.needsFirstResponderCheck = true
                self.editors[key] = ref
                // Deferred to next run loop iteration to coalesce multiple
                // didUpdateNotification fires into one checkFirstResponderChange() call.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.editors[key]?.needsFirstResponderCheck = false
                    self.editors[key]?.coordinator?.checkFirstResponderChange()
                }
            }
        }
        editors[key]?.windowObserver = observer
    }

    // MARK: - Public API

    // A focused editor answers Find itself, so this decides only whether the window's fallback has anything to search.
    internal var keyWindowHasEditor: Bool {
        editor(for: NSApp.keyWindow) != nil
    }

    internal func showFindPanelForKeyWindow() {
        guard let (coordinator, _) = editor(for: NSApp.keyWindow) else { return }
        coordinator.showFindPanel()
    }

    internal func showFindAndReplacePanelForKeyWindow() {
        guard let (coordinator, _) = editor(for: NSApp.keyWindow) else { return }
        coordinator.showFindAndReplacePanel()
    }

    internal var keyWindowEditorHasSelectionForFind: Bool {
        editor(for: NSApp.keyWindow)?.0.hasSelectionForFind ?? false
    }

    internal func useSelectionForFindInKeyWindow() {
        guard let (coordinator, _) = editor(for: NSApp.keyWindow) else { return }
        coordinator.useSelectionForFind()
    }

    internal func findNext() {
        guard let (coordinator, _) = editor(for: NSApp.keyWindow) else { return }
        coordinator.findNext()
    }

    internal func findPrevious() {
        guard let (coordinator, _) = editor(for: NSApp.keyWindow) else { return }
        coordinator.findPrevious()
    }

    internal func performFormatSQLForKeyWindow() {
        guard let (coordinator, _) = editor(for: NSApp.keyWindow) else { return }
        coordinator.performFormatSQL()
    }

    /// The query bar's Snippets menu, which sits above the editor it fills, as Format does.
    internal func insertSavedQueryForKeyWindow(_ sql: String) {
        guard let (coordinator, _) = editor(for: NSApp.keyWindow) else { return }
        coordinator.insertSavedQuery(sql)
    }

    internal func performRemoveInvisibleCharactersForKeyWindow() {
        guard let (coordinator, _) = editor(for: NSApp.keyWindow) else { return }
        coordinator.performRemoveInvisibleCharacters()
    }

    internal func performToggleFoldForKeyWindow() {
        guard let (coordinator, _) = editor(for: NSApp.keyWindow) else { return }
        coordinator.toggleFoldAtCursor()
    }

    internal func performFoldAllForKeyWindow() {
        guard let (coordinator, _) = editor(for: NSApp.keyWindow) else { return }
        coordinator.foldAll()
    }

    internal func performUnfoldAllForKeyWindow() {
        guard let (coordinator, _) = editor(for: NSApp.keyWindow) else { return }
        coordinator.unfoldAll()
    }

    internal func moveCursorToStatementForKeyWindow(_ direction: StatementNavigationDirection) {
        guard let (coordinator, _) = editor(for: NSApp.keyWindow) else { return }
        coordinator.moveCursorToStatement(direction)
    }

    // Inside the one editor, so the text and the connection cannot come from two editors in a multi-connection window.
    internal func runStatementAtCursorAndAdvanceForKeyWindow() {
        guard let (coordinator, _) = editor(for: NSApp.keyWindow) else { return }
        coordinator.runStatementAtCursorAndAdvance()
    }

    /// A run started in `window`, so every editor there ends its completion session. Not only the focused one:
    /// the run may come from a click on the query bar, which leaves the focus where it was, or from the menu.
    internal func dismissCompletions(in window: NSWindow?) {
        guard let window else { return }
        for ref in editors.values where ref.textView?.window === window {
            ref.coordinator?.dismissCompletions()
        }
    }

    // A large document writes its text to the tab on a delay; a run, save, close or quit reads the tab.
    internal func flushPendingText(forTab tabId: UUID, connectionId: UUID) {
        for ref in editors.values {
            guard let coordinator = ref.coordinator,
                  coordinator.tabID == tabId, coordinator.connectionId == connectionId else { continue }
            coordinator.controller?.flushPendingTextWriteback()
        }
    }

    internal func flushAllPendingText() {
        for ref in editors.values {
            ref.coordinator?.controller?.flushPendingTextWriteback()
        }
    }

    // False when the tab has no mounted editor, or it refused the edit: the caller writes the tab instead.
    internal func replaceText(forTab tabId: UUID, connectionId: UUID, in range: NSRange, with string: String) -> Bool {
        for ref in editors.values {
            guard let coordinator = ref.coordinator, let controller = coordinator.controller,
                  coordinator.tabID == tabId, coordinator.connectionId == connectionId else { continue }
            if controller.replaceTextAsOneEdit(in: range, with: string) { return true }
        }
        return false
    }

    // Clear Selection chosen with the pointer: AppKit never sends a bare Escape as a key equivalent (measured, macOS 26).
    // True when the editor consumed it, so the caller skips the grid's fallback.
    @discardableResult
    internal func handleEscapeFromMenu() -> Bool {
        guard let (coordinator, _) = editor(for: NSApp.keyWindow) else { return false }
        return coordinator.handleEscapeFromMenu()
    }

    // MARK: - Lookup

    // Window-scoped: these routes exist because focus is elsewhere. A switch can leave the outgoing editor registered,
    // so the focused one wins.
    private func editor(for window: NSWindow?) -> (SQLEditorCoordinator, TextView)? {
        guard let window else { return nil }
        var unfocused: (SQLEditorCoordinator, TextView)?
        for ref in editors.values {
            guard let coordinator = ref.coordinator, let textView = ref.textView,
                  textView.window === window else { continue }
            if window.firstResponder === textView { return (coordinator, textView) }
            unfocused = unfocused ?? (coordinator, textView)
        }
        return unfocused
    }

    private func purgeStaleEntries() {
        editors = editors.filter { $0.value.coordinator != nil && $0.value.textView != nil }
    }
}
