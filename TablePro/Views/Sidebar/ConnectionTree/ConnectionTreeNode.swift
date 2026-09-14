//
//  ConnectionTreeNode.swift
//  TablePro
//

import Foundation

/// A row above the object tree: a connection, or a folder holding connections.
///
/// Everything under a connection is a `DatabaseTreeNode` built by that connection's own
/// coordinator, so this type stops at the two kinds the window owns.
///
/// A reference type for the reason `SidebarOutlineNode` gives: the outline tracks rows by object
/// identity, and the status of a connection changes constantly while its row must stay the same
/// row. Handing the outline a fresh object for an id it already knows collapses everything under
/// it, which on this tree means collapsing a whole connected database tree because a ping came
/// back.
internal final class ConnectionTreeNode: SidebarOutlineNode {
    internal enum Kind: Equatable {
        case group(ConnectionGroup)
        case connection(UUID)
    }

    internal let id: String
    internal var kind: Kind

    /// Meaningful on a connection row only. A folder has no session.
    internal var status: ConnectionTreeStatus = .notConnected

    /// Whether the folder has anything in it after the current filter. A folder filtered down to
    /// nothing keeps no disclosure triangle, which is what stops a triangle opening onto no rows.
    internal var hasChildren = false

    internal init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    internal var connectionId: UUID? {
        guard case .connection(let id) = kind else { return nil }
        return id
    }

    internal var group: ConnectionGroup? {
        guard case .group(let group) = kind else { return nil }
        return group
    }

    /// A connection is expandable whatever its status, because opening it is how a user connects:
    /// a row with no triangle until it is already connected offers no way in. A folder is
    /// expandable only while it holds something.
    internal var isExpandable: Bool {
        switch kind {
        case .group: return hasChildren
        case .connection: return true
        }
    }

    /// Neither kind is a source list group row. AppKit draws one as a header and stops indenting
    /// its children, which would put a database at the same depth as the connection holding it.
    /// A folder here is an ordinary container row, the way a folder is in Xcode's navigator.
    internal var isGroupRow: Bool {
        false
    }
}
