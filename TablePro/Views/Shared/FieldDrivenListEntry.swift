//
//  FieldDrivenListEntry.swift
//  TablePro
//

import AppKit

/// One row of a `FieldDrivenList`, after sections have been flattened into the single index space
/// an `NSTableView` works in.
internal enum FieldDrivenListEntry<Item: Identifiable> where Item.ID: Hashable {
    case header(id: String, title: String, accentColor: NSColor?)
    case item(Item)

    internal var isHeader: Bool {
        guard case .header = self else { return false }
        return true
    }

    internal var itemId: Item.ID? {
        guard case .item(let item) = self else { return nil }
        return item.id
    }

    /// Identity, not content. A refilter that produces the same rows in the same order reloads
    /// nothing, which keeps the hosted SwiftUI views and their state alive.
    ///
    /// A header is the exception: only item rows are refreshed in place, so a header identified by
    /// its section id alone would keep a group's old name and colour on screen after a rename
    /// arrives from another device. Its drawn content is part of what identifies it.
    internal var identity: AnyHashable {
        switch self {
        case .header(let id, let title, let accentColor):
            return AnyHashable(HeaderIdentity(id: id, title: title, accentColor: accentColor))
        case .item(let item):
            return AnyHashable(item.id)
        }
    }

    /// A section contributes a header only when it is named and has something under it, so an
    /// empty section leaves no stray title behind.
    internal static func flatten(_ sections: [FieldDrivenListSection<Item>]) -> [FieldDrivenListEntry<Item>] {
        sections.flatMap { section -> [FieldDrivenListEntry<Item>] in
            guard !section.items.isEmpty else { return [] }
            let rows = section.items.map { FieldDrivenListEntry.item($0) }
            guard let title = section.title else { return rows }
            return [.header(id: section.id, title: title, accentColor: section.accentColor)] + rows
        }
    }
}

private struct HeaderIdentity: Hashable {
    let id: String
    let title: String
    let accentColor: NSColor?
}
