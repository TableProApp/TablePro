//
//  AgentSessionRailState.swift
//  TablePro
//

import Combine
import Foundation

/// Which row of a window's session rail is highlighted.
///
/// A highlighted row is not an open session. The rail moves its highlight on a click and on every
/// arrow key, and opening is a command of its own, so the two are held apart. The window reads the
/// highlight as well as the rail: a session command that names no session acts on the highlighted
/// one, the way a list command acts on the list's selection, and a highlight kept in the rail's own
/// `@State` was out of reach of every command that did not start in the rail.
@MainActor
internal final class AgentSessionRailState: ObservableObject {
    @Published internal var highlightedSessionId: UUID?
}
