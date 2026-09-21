//
//  TrailingPaneProxy.swift
//  TablePro
//
//  Protocol for coordinator → split view controller trailing-pane control.
//

import Foundation

/// How a coordinator asks the window to show one of its trailing surfaces.
///
/// There is one pane and several things that can be in it, so "is it open" is not a single question:
/// showing the assistant over an open inspector is a change even though the pane was already
/// visible. Each surface therefore gets its own visibility question and its own toggle.
///
/// The toggles are requirements rather than defaults built on the visibility questions, because
/// what a toggle does depends on the mode as well as the surface: in Agent mode the pane draws the
/// session's result whatever was stored, and the window alone knows that. Built on the stored
/// surface, the inspector's toggle collapsed the result column it had mistaken for the inspector.
@MainActor
internal protocol TrailingPaneProxy: AnyObject {
    var isInspectorVisible: Bool { get }
    var isAssistantVisible: Bool { get }
    func showInspector()
    func showAssistant()
    func hideTrailingPane()
    func toggleInspector()
    func toggleAssistant()

    /// Reveals the inspector for a selection the user made somewhere else, and only if that does
    /// not take the pane away from something they opened deliberately.
    func revealInspectorForSelection()
}
