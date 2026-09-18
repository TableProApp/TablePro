//
//  TrailingPaneProxy.swift
//  TablePro
//
//  Protocol for coordinator → split view controller trailing-pane control.
//

import Foundation

/// How a coordinator asks the window to show one of its two trailing surfaces.
///
/// There is one pane and two things that can be in it, so "is it open" is not a single question any
/// more: showing the assistant over an open inspector is a change even though the pane was already
/// visible. Each surface therefore gets its own visibility question and its own toggle, and the
/// toggles are what the menu bar and the toolbar drive.
@MainActor
internal protocol TrailingPaneProxy: AnyObject {
    var isInspectorVisible: Bool { get }
    var isAssistantVisible: Bool { get }
    func showInspector()
    func showAssistant()
    func hideTrailingPane()

    /// Reveals the inspector for a selection the user made somewhere else, and only if that does
    /// not take the pane away from something they opened deliberately.
    func revealInspectorForSelection()
}

internal extension TrailingPaneProxy {
    /// Toggling the surface already on screen closes the pane; toggling the other swaps to it and
    /// reveals the pane if it was closed. That is what makes two commands over one pane read the
    /// way two commands over two panes would.
    func toggleInspector() {
        if isInspectorVisible { hideTrailingPane() } else { showInspector() }
    }

    func toggleAssistant() {
        if isAssistantVisible { hideTrailingPane() } else { showAssistant() }
    }
}
