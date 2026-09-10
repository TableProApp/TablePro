//
//  SidebarMenuSection.swift
//  TablePro
//

import Foundation

/// One separator-delimited group of a sidebar contextual menu.
///
/// A group used to be an emergent property of append order: the item model carried a `.separator`
/// case, a spec built one flat array, and a helper swept up the leading, trailing and doubled
/// separators that shape made representable. Nothing could state how many groups a menu had, so
/// nothing could hold it to the HIG's "no more than about three groups", and the object tree's
/// table row drifted to five groups with seven unrelated commands in one of them.
///
/// Making the group the unit the spec returns puts that back under the type system: a separator is
/// no longer something a spec can emit, so it can no longer be emitted in the wrong place, and a
/// test can assert the group count directly.
internal struct SidebarMenuSection<Command: Equatable>: Equatable {
    internal let items: [SidebarMenuItem<Command>]

    internal init(_ items: [SidebarMenuItem<Command>]) {
        self.items = items
    }

    internal var isEmpty: Bool {
        items.isEmpty
    }
}

internal extension Array {
    /// An empty section contributes no separator, which is what makes a spec free to build a group
    /// out of items that may all turn out to be unavailable.
    func nonEmptySections<Command>() -> [SidebarMenuSection<Command>]
        where Element == SidebarMenuSection<Command> {
        filter { !$0.isEmpty }
    }
}

internal typealias DatabaseTreeMenuSection = SidebarMenuSection<SidebarMenuCommand>
internal typealias FavoritesMenuSection = SidebarMenuSection<FavoritesMenuCommand>
