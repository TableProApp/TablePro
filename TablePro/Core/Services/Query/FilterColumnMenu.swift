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
        depthLimit: Int = inlineDepthLimit,
        itemLimit: Int = inlineItemLimit
    ) -> FilterColumnMenu {
        let known = Set(columns)
        let nested = fieldPaths.filter { $0.depth > 1 && !known.contains($0.path) }

        var order: [String] = []
        var byParent: [String: [PluginFieldPath]] = [:]
        var inlineCount = 0
        var skipped = false

        for path in nested {
            guard path.depth <= depthLimit, inlineCount < itemLimit else {
                skipped = true
                continue
            }
            let parent = topLevelParent(of: path.path)
            if byParent[parent] == nil {
                order.append(parent)
            }
            byParent[parent, default: []].append(path)
            inlineCount += 1
        }

        let groups = order.compactMap { parent -> Group? in
            guard let paths = byParent[parent], !paths.isEmpty else { return nil }
            return Group(parent: parent, paths: paths)
        }

        return FilterColumnMenu(
            columns: columns,
            groups: groups,
            hasMorePaths: skipped || !nested.isEmpty
        )
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
