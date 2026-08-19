//
//  EditorEventRouter.swift
//  TablePro
//
//  Registry of the live SQL editors, used to dispatch window-scoped commands
//  to the editor in the key window.
//

@preconcurrency import AppKit
import CodeEditTextView

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

    /// Whether the key window has a SQL editor a find can fall back to. A focused editor answers the
    /// Find commands itself through the responder chain, so this only decides whether the window's
    /// last-resort handler has anything to search once nothing nearer has claimed them.
    internal var keyWindowHasEditor: Bool {
        editor(for: NSApp.keyWindow) != nil
    }

    internal func showFindPanelForKeyWindow() {
        guard let (coordinator, _) = editor(for: NSApp.keyWindow) else { return }
        coordinator.showFindPanel()
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

    /// Called by the SwiftUI "Clear Selection" menu when its bare-Escape key equivalent
    /// fires. A bare-key menu equivalent preempts every local event monitor in the key
    /// window, so the focused editor's completion popup, Vim interceptor, and
    /// first-responder handling never see the keystroke. Routes it to the key window's
    /// editor so it can dismiss its completion popup, hand the escape to Vim, and restore
    /// first responder. Returns whether the editor consumed the escape so the caller
    /// skips its cancelOperation fallback (the data grid's Clear Selection).
    @discardableResult
    internal func handleEscapeFromMenu() -> Bool {
        guard let (coordinator, _) = editor(for: NSApp.keyWindow) else { return false }
        return coordinator.handleEscapeFromMenu()
    }

    // MARK: - Lookup

    /// Window-scoped on purpose: every caller is a command the window's front content owns rather than
    /// whatever holds first responder, and the escape and find routes exist precisely because focus is
    /// somewhere else. A tab switch can leave the outgoing editor registered for a moment, and the
    /// dictionary has no order, so the focused editor wins before the remaining candidate is used.
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
