//
//  SidebarRootShape.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Which shape the sidebar's object outline takes at its root.
///
/// The three shapes used to be three separate views, two of them SwiftUI `List`s. A `List` hosted in
/// a bare `NSHostingController`, which is what this app has since it runs an AppKit lifecycle with no
/// SwiftUI scene, never answers a key equivalent and never draws an emphasized selection: its
/// backing view does not even respond to `moveDown:`. So all three shapes are one `NSOutlineView`
/// now, and this is the only thing that differs between them.
internal enum SidebarRootShape: Equatable {
    /// Object-kind sections: Tables, Views, Procedures and the rest, plus Recent and Redis keys.
    case flat
    /// Schema sections with lazily loaded tables, for engines that have no database dimension.
    case hierarchicalSchema
    /// Databases, then schemas, then objects.
    case databaseTree
}

internal enum SidebarRootShapeResolver {
    /// `supportsDatabaseTree` arrives already reduced rather than as its three constituent plugin
    /// lookups, so this stays a pure function of plain values and needs no plugin registry to test.
    internal static func resolve(
        groupingStrategy: GroupingStrategy,
        sidebarLayout: SidebarLayout,
        supportsDatabaseTree: Bool
    ) -> SidebarRootShape {
        if groupingStrategy == .hierarchicalSchema { return .hierarchicalSchema }
        if supportsDatabaseTree, sidebarLayout == .tree { return .databaseTree }
        return .flat
    }
}
