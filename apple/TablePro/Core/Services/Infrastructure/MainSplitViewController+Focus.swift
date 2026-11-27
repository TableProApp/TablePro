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
    // AppKit picks a first responder once, at first show, from the views that exist then, and the editor, the grid
    // and the object list are SwiftUI that arrives later. This container takes no focus and names no key view after
    // it until the window is on screen (`WorkspacePaneHost`), so the window stays vacant and the content adopts it
    // once built (`SQLEditorCoordinator`, `SidebarOutlineView`). Left to AppKit, the pick was the connections strip
    // (Command W closed the connection) or the sidebar filter.
    var initialFirstResponderContainer: NSView {
        detailPaneHost.view
    }

    var detailPaneHoldsKeyboard: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: detailPaneHost.view)
    }

    // A connection switch takes the outgoing editor or grid out of the window. The keyboard follows into the incoming
    // connection's editor or grid; with neither built yet, its object list adopts the empty window (`SidebarOutlineView`).
    func keepKeyboardInDetailPane(detailHeldKeyboard: Bool) {
        guard detailHeldKeyboard, let window = view.window, window.firstResponder === window,
              let selected = workspaces.selected, selected.detailMode == .browse else { return }
        guard !focusQueryEditor() else { return }
        // Not the Focus Results command: a switch must not expand a results pane the user collapsed.
        _ = selected.sessionState?.coordinator.focusActiveGrid()
    }

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
    /// hidden its content is not built yet, and revealing it is a visible outcome of its own. Agent
    /// mode draws no inspector at all, so there the command is dimmed.
    var canFocusInspector: Bool {
        guard TrailingPaneCommandResolver.inspectorFocus(trailingPaneCommandContext) != nil else { return false }
        guard isInspectorVisible else { return true }
        return workspaces.selected?.panes.inspector.view.firstKeyViewDescendant != nil
    }

    /// Into the trailing pane while browsing, and into the content column in Agent mode, where the
    /// same conversation is drawn. The pane beside it holds the result there, and revealing the
    /// assistant first would have written a browse preference and focused a pane with no window.
    @discardableResult
    func focusAssistantPane() -> Bool {
        switch TrailingPaneCommandResolver.assistantFocus(trailingPaneCommandContext) {
        case .conversation?:
            return focusComposer(in: shownConversation)
        case .trailingPane?:
            showAssistant()
            return focusComposer(in: workspaces.selected?.panes.assistant.view)
        case nil:
            return false
        }
    }

    /// The conversation column is checked for a composer because Agent mode draws one only once a
    /// session and a provider are there to answer it.
    var canFocusAssistant: Bool {
        switch TrailingPaneCommandResolver.assistantFocus(trailingPaneCommandContext) {
        case .conversation?:
            return shownConversation?.firstDescendant(of: ChatComposerNSTextView.self) != nil
        case .trailingPane?:
            return true
        case nil:
            return false
        }
    }

    /// Asked only while the conversation is the tree in the detail column. A connection that drops
    /// in Agent mode hands the column to the unavailable screen and keeps the conversation built
    /// behind it, detached, and a search of the pane alone still found its composer there: the
    /// command stayed enabled, and `makeFirstResponder` on a view in no window reported success
    /// while it moved focus off Retry and onto the window itself.
    private var shownConversation: NSView? {
        guard let selected = workspaces.selected, selected.detailMode == .agent else { return nil }
        return selected.panes.agentConversation.view
    }

    /// Asked only of browse content the window is showing. Agent mode keeps the editor mounted
    /// behind the conversation, detached, and a search of the tree alone would find it there and
    /// offer to focus a view that is in no window.
    private var mountedQueryEditor: TextView? {
        guard let selected = workspaces.selected, selected.detailMode == .browse else { return nil }
        return selected.panes.detail.view.firstDescendant(of: TextView.self)
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

    /// The composer rather than the first view that takes the keyboard. A transcript's messages are
    /// selectable text and come first in the tree, and Focus Assistant is a request to type.
    private func focusComposer(in paneView: NSView?) -> Bool {
        guard let paneView, let window = view.window else { return false }
        paneView.layoutSubtreeIfNeeded()
        let composer: NSView? = paneView.firstDescendant(of: ChatComposerNSTextView.self)
        guard let target = composer ?? paneView.firstKeyViewDescendant else { return false }
        return window.makeFirstResponder(target)
    }
}
