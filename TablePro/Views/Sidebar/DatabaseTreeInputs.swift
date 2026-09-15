//
//  DatabaseTreeInputs.swift
//  TablePro
//

import Foundation
import SwiftUI
import TableProPluginKit

/// Everything the object tree coordinator reads from outside itself.
///
/// It used to take the `DatabaseTreeOutlineView` struct whole, which tied the coordinator to being
/// driven by a SwiftUI representable. One outline view now lists every connection and the router
/// that owns it is an `NSViewController`, so these values have to exist without a `View` to read
/// them off. `SidebarRowSize` is SwiftUI's own type, which is why the import stays.
///
/// `selectedTables` is deliberately absent: the coordinator reads it from `windowState`, and the
/// representable declares it only so SwiftUI re-runs `updateNSView` when it moves.
internal struct DatabaseTreeInputs {
    internal let connectionId: UUID
    internal let databaseType: DatabaseType
    internal weak var mainCoordinator: MainContentCoordinator?
    internal let windowState: WindowSidebarState?
    internal let sidebarState: SharedSidebarState?
    internal weak var viewModel: SidebarViewModel?
    internal let pendingTruncates: Set<DatabaseTreeTableRef>
    internal let pendingDeletes: Set<DatabaseTreeTableRef>
    internal let searchText: String
    internal let isConnected: Bool
    internal let activeDatabase: String?
    internal let activeSchema: String?
    internal let showRecentTables: Bool
    internal let showSystemContainers: Bool
    internal let rowSize: SidebarRowSize
}
