//
//  FieldDrivenListEntry.swift
//  TablePro
//

import Foundation

// A `FieldDrivenList` row after sections are flattened into the single index space an `NSTableView` works in.
internal enum FieldDrivenListEntry<Item: Identifiable> where Item.ID: Hashable {
    case header(id: String, title: String)
    case item(Item)

    internal var isHeader: Bool {
        guard case .header = self else { return false }
        return true
    }

    internal var itemId: Item.ID? {
        guard case .item(let item) = self else { return nil }
        return item.id
    }

    // Only item rows refresh in place, so a header's title is part of its identity: a rename from another device redraws it.
    internal var identity: AnyHashable {
        switch self {
        case .header(let id, let title):
            return AnyHashable(HeaderIdentity(id: id, title: title))
        case .item(let item):
            return AnyHashable(item.id)
        }
    }

    // A section with no rows contributes no header, so an empty section leaves no stray title behind.
    internal static func flatten(_ sections: [FieldDrivenListSection<Item>]) -> [FieldDrivenListEntry<Item>] {
        sections.flatMap { section -> [FieldDrivenListEntry<Item>] in
            guard !section.items.isEmpty else { return [] }
            let rows = section.items.map { FieldDrivenListEntry.item($0) }
            guard let title = section.title else { return rows }
            return [.header(id: section.id, title: title)] + rows
        }
    }
}

private struct HeaderIdentity: Hashable {
    let id: String
    let title: String
}
