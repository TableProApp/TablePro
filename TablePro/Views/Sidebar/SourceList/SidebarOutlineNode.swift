//
//  SidebarOutlineNode.swift
//  TablePro
//

import Foundation

/// What a sidebar list needs from a row to be able to draw it.
///
/// A reference type because `NSOutlineView` tracks rows by object identity, which is what lets a
/// reload keep the expansion and selection a user set. Both coordinators cache their nodes by `id`
/// and mutate the cached instance rather than building a new one; handing the outline a fresh
/// object for an id it already knows silently collapses everything under it.
/// Deliberately not `@MainActor`. A node is only ever touched from the main thread, but isolating
/// the protocol isolates the conforming class along with it, and both node types carry pure static
/// id builders that a selection or a persisted key resolves without a main-actor hop.
internal protocol SidebarOutlineNode: AnyObject {
    var id: String { get }
    var isExpandable: Bool { get }
    /// A bucket rather than an object: AppKit draws it as a source list group row, at its own
    /// height, with its children laid out at the group's depth rather than one level in.
    var isGroupRow: Bool { get }
}
