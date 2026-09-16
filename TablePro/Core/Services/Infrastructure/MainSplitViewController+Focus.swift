//
//  MainSplitViewController+Focus.swift
//  TablePro
//

import AppKit
import TableProTextEngine

/// Tab is the macOS mechanism for moving focus inside a window, and it works here because the window
/// keeps its key view loop current (`NSWindow.keepsKeyViewLoopCurrent()`). These commands exist for
/// the two cases it cannot serve: a jump across several panes, and the SQL editor, which keeps Tab
/// and Shift+Tab for its own indentation and so cannot be left with either.
///
/// Two rules hold for all of them. A pane is revealed before it is focused, because
/// `makeFirstResponder` accepts a hidden view and reports success. And the view that takes the
/// keyboard is found in the pane's own subtree, which is what scopes it to the selected connection:
/// a window hosting several connections has several editors registered at once, and a window-wide
/// registry cannot tell them apart.
internal extension MainSplitViewController {
    @discardableResult
    func focusQueryEditor() -> Bool {
        guard let textView = mountedQueryEditor, let window = view.window else { return false }
        return window.makeFirstResponder(textView)
    }

    var canFocusEditor: Bool {
        mountedQueryEditor != nil
    }

    @discardableResult
    func focusResultGrid() -> Bool {
        commandActions?.focusActiveGrid() ?? false
    }

    var canFocusResults: Bool {
        commandActions?.canFocusActiveGrid ?? false
    }

    @discardableResult
    func focusInspectorPane() -> Bool {
        guard canFocusInspector else { return false }
        showInspector()
        return focusFirstKeyView(in: workspaces.selected?.panes.inspector.view)
    }

    /// A visible inspector with nothing to inspect draws a `ContentUnavailableView` and holds no key
    /// view, so the command would reveal a pane it cannot focus and report success. While the pane is
    /// hidden its content is not built yet, and revealing it is a visible outcome of its own.
    var canFocusInspector: Bool {
        guard canToggleTrailingPane else { return false }
        guard isInspectorVisible else { return true }
        return workspaces.selected?.panes.inspector.view.firstKeyViewDescendant != nil
    }

    @discardableResult
    func focusAssistantPane() -> Bool {
        guard canFocusAssistant else { return false }
        showAssistant()
        return focusFirstKeyView(in: workspaces.selected?.panes.assistant.view)
    }

    var canFocusAssistant: Bool {
        canRevealAssistant
    }

    /// The one answer to "can the assistant be put on screen", shared with the View menu's toggle.
    /// The assistant is the single surface a setting can take away, so the command goes with it.
    var canRevealAssistant: Bool {
        isAssistantVisible || (currentPane == .content && AppSettingsManager.shared.ai.enabled)
    }

    private var mountedQueryEditor: TextView? {
        workspaces.selected?.panes.detail.view.firstDescendant(of: TextView.self)
    }

    /// Revealing a pane parents its views on the next layout pass, so the search has to run after
    /// one. Without it a pane revealed by the same command it is focused from has no key view yet
    /// and the command silently does nothing the first time it is used.
    private func focusFirstKeyView(in paneView: NSView?) -> Bool {
        guard let paneView, let window = view.window else { return false }
        paneView.layoutSubtreeIfNeeded()
        guard let target = paneView.firstKeyViewDescendant else { return false }
        return window.makeFirstResponder(target)
    }
}
