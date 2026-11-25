//
//  FilterColumnMenu.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The choices a filter row's column control offers: the flat columns the grid shows, plus the
/// nested paths a document store reports for the same collection.
///
/// A document store types a nested object as one opaque column, so `customer.country` never
/// appears among the grid's columns even though it is queryable. Only paths shallow enough to
/// stay readable go in the menu; the rest are reachable through the searchable picker, which is
/// also the only route to a field the sample missed.
struct FilterColumnMenu: Equatable {
    struct Group: Equatable, Identifiable {
        let parent: String
        let paths: [PluginFieldPath]

        var id: String { parent }
    }

    let columns: [String]
    let groups: [Group]
    let hasMorePaths: Bool

    static let inlineDepthLimit = 2
    static let inlineItemLimit = 60

    static let empty = FilterColumnMenu(columns: [], groups: [], hasMorePaths: false)

    static func build(
        columns: [String],
        fieldPaths: [PluginFieldPath],
        order: FilterColumnOrder,
        depthLimit: Int = inlineDepthLimit,
        itemLimit: Int = inlineItemLimit
    ) -> FilterColumnMenu {
        let known = Set(columns)
        let nested = fieldPaths.filter { $0.depth > 1 && !known.contains($0.path) }

        // Picked in the driver's order before any sorting, so the order setting never changes which paths are inline.
        var inline: [PluginFieldPath] = []
        var skipped = false
        for path in nested {
            guard path.depth <= depthLimit, inline.count < itemLimit else {
                skipped = true
                continue
            }
            inline.append(path)
        }

        return FilterColumnMenu(
            columns: order.ordered(columns),
            groups: grouped(inline, order: order),
            hasMorePaths: skipped || !nested.isEmpty
        )
    }

    static func grouped(_ paths: [PluginFieldPath], order: FilterColumnOrder) -> [Group] {
        var parents: [String] = []
        var byParent: [String: [PluginFieldPath]] = [:]
        for path in paths {
            let parent = topLevelParent(of: path.path)
            if byParent[parent] == nil {
                parents.append(parent)
            }
            byParent[parent, default: []].append(path)
        }

        let groups = parents.compactMap { parent -> Group? in
            guard let paths = byParent[parent], !paths.isEmpty else { return nil }
            return Group(parent: parent, paths: paths)
        }
        guard order == .alphabetical else { return groups }
        return groups
            .map { group in
                Group(
                    parent: group.parent,
                    paths: group.paths.sorted { FilterColumnOrder.precedesAlphabetically($0.path, $1.path) }
                )
            }
            .sorted { FilterColumnOrder.precedesAlphabetically($0.parent, $1.parent) }
    }

    static func topLevelParent(of path: String) -> String {
        guard let separator = path.firstIndex(of: ".") else { return path }
        return String(path[path.startIndex ..< separator])
    }

    /// Array ancestors of a path, as reported by the driver. Only a path with exactly one is
    /// offered the same-element choice: with two or more, the correct query needs nested
    /// `$elemMatch` operators whose semantics TablePro does not yet express.
    static func elementScope(for column: String, in fieldPaths: [PluginFieldPath]) -> String? {
        guard let match = fieldPaths.first(where: { $0.path == column }) else { return nil }
        guard match.arrayPrefixes.count == 1 else { return nil }
        return match.arrayPrefixes.first
    }

    func contains(_ column: String) -> Bool {
        columns.contains(column) || groups.contains { $0.paths.contains { $0.path == column } }
    }
}

// A filter bar redraws on every keystroke in a value field, and sorting a wide table's columns each time shows.
@MainActor
final class FilterColumnMenuCache {
    private var inputs: (columns: [String], fieldPaths: [PluginFieldPath], order: FilterColumnOrder)?
    private var menu = FilterColumnMenu.empty

    func menu(columns: [String], fieldPaths: [PluginFieldPath], order: FilterColumnOrder) -> FilterColumnMenu {
        if let inputs, inputs.order == order, inputs.columns == columns, inputs.fieldPaths == fieldPaths {
            return menu
        }
        menu = FilterColumnMenu.build(columns: columns, fieldPaths: fieldPaths, order: order)
        inputs = (columns, fieldPaths, order)
        return menu
    }
}
