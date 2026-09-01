//
//  JSONRowFilter.swift
//  TablePro
//
//  Text and /regex/ filtering over a row's JSON tree.
//

import Foundation

struct JSONRowMatcher: Sendable {
    private enum Kind {
        case substring(String)
        case regex(NSRegularExpression)
    }

    private let kind: Kind

    /// `/…/` is read as a regular expression, anything else as a case-insensitive substring. A
    /// trailing slash is required, so a reader typing a path such as `a/b` still gets a substring.
    static func make(query: String) -> JSONRowFilterQuery {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if trimmed.count >= 2, trimmed.hasPrefix("/"), trimmed.hasSuffix("/") {
            let pattern = String(trimmed.dropFirst().dropLast())
            guard !pattern.isEmpty else { return .empty }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return .invalidRegex
            }
            return .matcher(JSONRowMatcher(kind: .regex(regex)))
        }
        return .matcher(JSONRowMatcher(kind: .substring(trimmed)))
    }

    func matches(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        switch kind {
        case .substring(let needle):
            return text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .regex(let regex):
            let range = NSRange(location: 0, length: (text as NSString).length)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        }
    }
}

enum JSONRowFilterQuery: Sendable {
    case empty
    case invalidRegex
    case matcher(JSONRowMatcher)
}

enum JSONRowFilter {
    /// Paths to keep for a filter: every node that matches, plus every ancestor of one, so a match
    /// nested three levels down still arrives with the keys that lead to it.
    static func visiblePaths(
        root: JSONRowNode,
        fetchedForeignKeys: [JSONNodePath: JSONRowNode],
        matcher: JSONRowMatcher
    ) -> Set<JSONNodePath> {
        var visible: Set<JSONNodePath> = []
        _ = collect(
            node: root,
            fetched: fetchedForeignKeys,
            matcher: matcher,
            keepsEverything: false,
            into: &visible
        )
        return visible
    }

    /// One walk, one visit per node.
    ///
    /// A key that matches keeps what it holds, decided before descending and carried down as
    /// `keepsEverything`, so a chain of matching ancestors costs one pass rather than one pass per
    /// ancestor over the same leaves. Keeping the container alone left it drawn as `{…}` with a
    /// disclosure control that could not open it, because a filtered tree takes its expansion from
    /// what survived the filter rather than from the reader's expanded set.
    ///
    /// Only the *key* keeps a subtree. A value that matches keeps its own line and the keys that
    /// lead to it: an expanded foreign key carries both its own scalar and the fetched row's
    /// fields, so treating a value match the same way answered a search for `1` with every column
    /// of the referenced row.
    private static func collect(
        node: JSONRowNode,
        fetched: [JSONNodePath: JSONRowNode],
        matcher: JSONRowMatcher,
        keepsEverything: Bool,
        into visible: inout Set<JSONNodePath>
    ) -> Bool {
        let keyMatches = node.key.text.map(matcher.matches) ?? false
        let keepsDescendants = keepsEverything || keyMatches
        var subtreeMatched = false

        for child in children(of: node, fetched: fetched) {
            if collect(
                node: child,
                fetched: fetched,
                matcher: matcher,
                keepsEverything: keepsDescendants,
                into: &visible
            ) {
                subtreeMatched = true
            }
        }

        guard keepsDescendants || subtreeMatched || scalarMatches(node, matcher: matcher) else {
            return false
        }
        visible.insert(node.path)
        return true
    }

    static func children(of node: JSONRowNode, fetched: [JSONNodePath: JSONRowNode]) -> [JSONRowNode] {
        if node.foreignKey != nil, let expansion = fetched[node.path] {
            return expansion.children
        }
        return node.children
    }

    private static func scalarMatches(_ node: JSONRowNode, matcher: JSONRowMatcher) -> Bool {
        guard let scalar = node.scalar else { return false }
        return matcher.matches(scalar.searchableText)
    }
}
