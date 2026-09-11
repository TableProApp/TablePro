//
//  ConnectionWorkspaceContentMode.swift
//  TablePro
//

import Foundation

/// What a connection's window shows: the object browser and editor, or the assistant.
///
/// Deliberately not a `ConnectionWindowPhase` case. That enum's vocabulary is connection health,
/// and the two are orthogonal: an assistant-mode window can be connecting. Mode is read only
/// after `ConnectionWindowPaneResolver` has already resolved the pane.
///
/// Also deliberately not `AIChatMode`. That one names which tools may run (Ask, Edit, Agent) and
/// lives in the composer. Two controls both labelled Agent, meaning different things, is a support
/// ticket generator, so the toolbar says Assistant and neither mode drives the other.
internal enum ConnectionWorkspaceContentMode: String, Codable, Equatable, Sendable, CaseIterable {
    case browse
    case assistant
}
