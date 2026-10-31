//
//  PostgreSQLViewRowEditing.swift
//  PostgreSQLDriverPlugin
//
//  Works out whether the grid may write rows through a view. The server answers whether the view
//  is updatable; the view's stored query says which base column each view column shows. Pure, so
//  it is testable without a server.
//

import Foundation
import TableProPluginKit

enum PostgreSQLViewRowEditing {
    /// The base column one view column shows, as `pg_rewrite` stores it: `resorigtbl` and
    /// `resorigcol` are the table's OID and attribute number, zero for a computed column.
    struct TargetOrigin: Equatable {
        let viewAttributeNumber: Int
        let tableOID: String
        let columnNumber: Int
    }

    /// Bits 4 (UPDATE) and 16 (DELETE) of `pg_relation_is_updatable`, the test
    /// `information_schema.views.is_updatable` applies, read directly so a view the user may not
    /// see in `information_schema` still gets an answer.
    static func viewQuery(name: String, schema: String) -> String {
        """
        SELECT
            c.oid::text,
            (pg_catalog.pg_relation_is_updatable(c.oid, false) & 20) = 20,
            r.ev_action::text
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_catalog.pg_rewrite r ON r.ev_class = c.oid AND r.rulename = '_RETURN'
        WHERE c.relkind = 'v'
          AND n.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema))
          AND c.relname = \(PostgreSQLObjectQueries.quoteLiteral(name))
        """
    }

    /// The view's column names by number, then the base table's primary key column numbers in key
    /// order, told apart by the first column.
    static func columnsAndKeyQuery(viewOID: String, baseTableOID: String) -> String {
        """
        SELECT 'v', a.attnum::text, a.attname::text, 0
        FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = \(PostgreSQLObjectQueries.quoteLiteral(viewOID))::oid
          AND a.attnum > 0 AND NOT a.attisdropped
        UNION ALL
        SELECT 'k', k.attnum::text, NULL, k.ord
        FROM pg_catalog.pg_index i
        CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
        WHERE i.indrelid = \(PostgreSQLObjectQueries.quoteLiteral(baseTableOID))::oid
          AND i.indisprimary
        ORDER BY 1, 4
        """
    }

    static func resolve(
        isUpdatable: Bool,
        origins: [TargetOrigin],
        viewColumnNames: [Int: String],
        baseKeyColumnNumbers: [Int]
    ) -> PluginViewRowEditing {
        let baseTables = Set(origins.map(\.tableOID))
        let columnOrigins = origins.compactMap { origin -> PluginViewColumnOrigin? in
            guard let name = viewColumnNames[origin.viewAttributeNumber] else { return nil }
            return PluginViewColumnOrigin(viewColumn: name, baseColumn: String(origin.columnNumber))
        }
        return PluginViewRowEditing.resolve(
            isUpdatable: isUpdatable,
            baseTableCount: baseTables.count,
            baseKeyColumns: baseKeyColumnNumbers.map(String.init),
            origins: columnOrigins
        )
    }

    /// The origins of the outermost query's target list. A sub-select in the view's WHERE clause
    /// stores a target list of its own earlier in the text, so this follows the nesting rather
    /// than matching the first `:targetList`.
    static func targetOrigins(nodeTree: String) -> [TargetOrigin] {
        let tokens = NodeTreeToken.tokenize(nodeTree)
        guard let queryIndex = tokens.firstIndex(where: { $0.text == "QUERY" }) else { return [] }
        let queryDepth = tokens[queryIndex].depth
        guard let listIndex = tokens[queryIndex...].firstIndex(where: {
            $0.depth == queryDepth && $0.text == ":targetList"
        }) else { return [] }

        let entryDepth = queryDepth + 2
        var origins: [TargetOrigin] = []
        var fields: [String: String] = [:]
        var index = tokens.index(after: listIndex)
        guard index < tokens.count, tokens[index].text == "(" else { return [] }
        index += 1

        while index < tokens.count, tokens[index].depth > queryDepth {
            let token = tokens[index]
            if token.text == "}", token.depth == entryDepth - 1 {
                if let origin = origin(from: fields) { origins.append(origin) }
                fields = [:]
            } else if token.depth == entryDepth, token.text.hasPrefix(":"), index + 1 < tokens.count {
                let value = tokens[index + 1]
                if value.depth == entryDepth, !value.isBracket {
                    fields[token.text] = value.text
                }
            }
            index += 1
        }
        return origins
    }

    private static func origin(from fields: [String: String]) -> TargetOrigin? {
        guard fields[":resjunk"] != "true",
              let resno = fields[":resno"].flatMap(Int.init),
              let table = fields[":resorigtbl"], table != "0",
              let column = fields[":resorigcol"].flatMap(Int.init), column > 0
        else { return nil }
        return TargetOrigin(viewAttributeNumber: resno, tableOID: table, columnNumber: column)
    }
}

/// One token of a `pg_node_tree` text, with the number of brackets open before it. A closing
/// bracket carries the depth of its opening one.
private struct NodeTreeToken {
    let text: String
    let depth: Int

    var isBracket: Bool { ["{", "}", "(", ")"].contains(text) }

    static func tokenize(_ text: String) -> [NodeTreeToken] {
        var tokens: [NodeTreeToken] = []
        var depth = 0
        var word = ""
        var escaped = false

        func flush() {
            if !word.isEmpty { tokens.append(NodeTreeToken(text: word, depth: depth)) }
            word = ""
        }

        for character in text {
            if escaped {
                word.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case "{", "(":
                flush()
                tokens.append(NodeTreeToken(text: String(character), depth: depth))
                depth += 1
            case "}", ")":
                flush()
                depth -= 1
                tokens.append(NodeTreeToken(text: String(character), depth: depth))
            case " ", "\n", "\t":
                flush()
            default:
                word.append(character)
            }
        }
        flush()
        return tokens
    }
}
