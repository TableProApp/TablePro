//
//  ConnectionTreeActivationResolver.swift
//  TablePro
//

import Foundation

/// What the user did to a row in the connection tree.
internal enum ConnectionTreeGesture: Equatable, Sendable {
    case singleClick
    case doubleClick
    /// The disclosure triangle, carrying the state the row was in when it was clicked.
    case disclosure(isExpanded: Bool)
}

/// What the tree does about it.
internal enum ConnectionTreeActivation: Equatable, Sendable {
    case connect
    case expand
    case collapse
    case select
    case nothing
}

/// Turns a gesture on a connection tree row into the one thing the tree does about it.
///
/// Pure and exhaustive for the same reason `ConnectionWindowPhaseMachine` is: the interesting
/// cases are the ones nobody clicks by hand, and a table of them is the only way they get covered.
internal enum ConnectionTreeActivationResolver {
    internal static func resolve(
        status: ConnectionTreeStatus,
        gesture: ConnectionTreeGesture
    ) -> ConnectionTreeActivation {
        switch gesture {
        case .singleClick:
            return .select
        case .doubleClick:
            return doubleClick(status: status)
        case .disclosure(let isExpanded):
            return disclosure(status: status, isExpanded: isExpanded)
        }
    }

    /// A folder has no session, so it only ever opens and closes.
    internal static func resolveGroup(gesture: ConnectionTreeGesture, isExpanded: Bool) -> ConnectionTreeActivation {
        switch gesture {
        case .singleClick:
            return .select
        case .doubleClick, .disclosure:
            return isExpanded ? .collapse : .expand
        }
    }

    private static func doubleClick(status: ConnectionTreeStatus) -> ConnectionTreeActivation {
        switch status {
        case .notConnected, .failed:
            return .connect
        case .connecting:
            /// Nothing, rather than cancel. A double-click lands on a row the user is waiting for,
            /// and making the second click of an impatient double abandon the connect is how a
            /// list of connections becomes hostile. Cancel is the button on the pane and the item
            /// in the row's menu, both of which say what they do.
            return .nothing
        case .connected:
            return .expand
        }
    }

    /// Opening a connection that is not up yet is a connect. That is the gesture Navicat, DataGrip
    /// and Sequel Ace all answer that way, and a triangle that opens onto an empty row instead
    /// leaves the user with nothing to click.
    private static func disclosure(
        status: ConnectionTreeStatus,
        isExpanded: Bool
    ) -> ConnectionTreeActivation {
        if isExpanded { return .collapse }
        switch status {
        case .notConnected, .failed:
            return .connect
        case .connecting:
            return .nothing
        case .connected:
            return .expand
        }
    }
}

/// Connections waiting to be opened as soon as their connect lands.
///
/// Expanding is the user's gesture, not the session's, so it is honoured once and then forgotten.
/// Re-expanding on every later reconnect would reopen a tree the user had since collapsed, and the
/// health monitor reconnects on its own schedule.
internal struct ConnectionTreeAutoExpansion: Equatable, Sendable {
    private var pending: Set<UUID> = []

    internal init() {}

    internal mutating func expect(_ connectionId: UUID) {
        pending.insert(connectionId)
    }

    internal mutating func cancel(_ connectionId: UUID) {
        pending.remove(connectionId)
    }

    /// True once, for a connection that was waiting and has now connected.
    internal mutating func consume(_ connectionId: UUID, status: ConnectionTreeStatus) -> Bool {
        guard status == .connected else {
            if status == .failed { pending.remove(connectionId) }
            return false
        }
        return pending.remove(connectionId) != nil
    }

    internal var isEmpty: Bool {
        pending.isEmpty
    }
}
