import Foundation
import TableProPluginKit
import TableProPostgreSQLCore

enum PostgreSQLViewRowEditing {
    static let maxViewDepth = 8
    // pg_relation_is_updatable is 9.3, unnest WITH ORDINALITY is 9.4.
    static let minimumServerVersion: Int32 = 90_400

    struct ColumnOrigin: Hashable {
        let relationOID: String
        let attributeNumber: Int
    }

    struct Relation: Equatable {
        let oid: String
        let kind: String
        let schema: String
        let name: String
        let events: Int
        let hasRules: Bool
        let hasInsteadTrigger: Bool
        // Keyed by the view's attribute number; a computed column has no entry.
        let origins: [Int: ColumnOrigin]

        var isView: Bool { kind == "v" }

        init?(row: [String?]) {
            guard let oid = cell(row, 0), let kind = cell(row, 1), let schema = cell(row, 2), let name = cell(row, 3)
            else { return nil }
            self.oid = oid
            self.kind = kind
            self.schema = schema
            self.name = name
            events = cell(row, 4).flatMap(Int.init) ?? 0
            hasRules = PostgreSQLCatalogBoolean.isTrue(cell(row, 5))
            hasInsteadTrigger = PostgreSQLCatalogBoolean.isTrue(cell(row, 6))
            origins = kind == "v" ? targetOrigins(nodeTree: cell(row, 7) ?? "") : [:]
        }
    }

    enum Step: Equatable {
        case notAView
        case readOnly(PluginViewReadOnlyReason)
        case readRelation(oid: String)
        case readColumns(viewOID: String, baseOID: String, baseSchema: String)
    }

    static func relationQuery(name: String, schema: String) -> String {
        relationQuery(matching: """
            n.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema)) \
            AND c.relname = \(PostgreSQLObjectQueries.quoteLiteral(name))
            """)
    }

    static func relationQuery(oid: String) -> String {
        relationQuery(matching: "c.oid = \(PostgreSQLObjectQueries.quoteLiteral(oid))::oid")
    }

    // Every INSTEAD OF trigger counts: one marked disabled still answers UPDATE 1 and changes nothing.
    private static func relationQuery(matching condition: String) -> String {
        """
        SELECT
            c.oid::text,
            c.relkind::text,
            n.nspname::text,
            c.relname::text,
            pg_catalog.pg_relation_is_updatable(c.oid, false)::text,
            EXISTS (
                SELECT 1 FROM pg_catalog.pg_rewrite r
                WHERE r.ev_class = c.oid AND r.rulename <> '_RETURN'
            ),
            EXISTS (
                SELECT 1 FROM pg_catalog.pg_trigger tg
                WHERE tg.tgrelid = c.oid AND (tg.tgtype & 64) <> 0
            ),
            rt.ev_action::text
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_catalog.pg_rewrite rt ON rt.ev_class = c.oid AND rt.rulename = '_RETURN'
        WHERE \(condition)
        """
    }

    static func viewColumnsQuery(viewOID: String) -> String {
        """
        SELECT
            a.attnum::text,
            a.attname::text,
            pg_catalog.pg_column_is_updatable(a.attrelid, a.attnum, false)
        FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = \(PostgreSQLObjectQueries.quoteLiteral(viewOID))::oid
          AND a.attnum > 0
          AND NOT a.attisdropped
        ORDER BY a.attnum
        """
    }

    static func baseColumnsQuery(baseOID: String, capabilities: PostgreSQLCapabilities) -> String {
        let oid = "\(PostgreSQLObjectQueries.quoteLiteral(baseOID))::oid"
        let identity = capabilities.hasIdentityColumns ? "a.attidentity::text" : "''"
        let generated = capabilities.hasGeneratedColumns ? "a.attgenerated::text" : "''"
        // indkey lists INCLUDE columns after the key from 11 on; indnkeyatts counts the key ones.
        let keyCount = capabilities.hasCoveringIndexes ? "i.indnkeyatts" : "i.indnatts"
        return """
            SELECT
                a.attnum::text,
                a.attname::text,
                a.attnotnull,
                pg_catalog.pg_get_expr(d.adbin, d.adrelid),
                \(identity),
                \(generated),
                k.ord::text
            FROM pg_catalog.pg_attribute a
            LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            LEFT JOIN (
                SELECT key.attnum, key.ord
                FROM pg_catalog.pg_index i
                CROSS JOIN LATERAL pg_catalog.unnest(i.indkey) WITH ORDINALITY AS key(attnum, ord)
                WHERE i.indrelid = \(oid) AND i.indisprimary AND key.ord <= \(keyCount)
            ) k ON k.attnum = a.attnum
            WHERE a.attrelid = \(oid)
              AND a.attnum > 0
              AND NOT a.attisdropped
            ORDER BY a.attnum
            """
    }

    static func step(_ chain: inout [Relation], row: [String?]?) -> Step {
        guard let relation = row.flatMap(Relation.init(row:)) else {
            return chain.isEmpty ? .notAView : .readOnly(.notUpdatable)
        }
        guard relation.isView else {
            guard let outer = chain.first else { return .notAView }
            chain.append(relation)
            guard operations(events: outer.events).contains(.update) else { return .readOnly(.notUpdatable) }
            return .readColumns(viewOID: outer.oid, baseOID: relation.oid, baseSchema: relation.schema)
        }
        chain.append(relation)
        if relation.hasRules || relation.hasInsteadTrigger { return .readOnly(.writesRunTriggers) }
        let bases = Set(relation.origins.values.map(\.relationOID))
        guard bases.count <= 1 else { return .readOnly(.readsSeveralTables) }
        guard let base = bases.first, chain.count <= maxViewDepth else { return .readOnly(.notUpdatable) }
        return .readRelation(oid: base)
    }

    // Bits are 1 << CmdType: UPDATE 2, INSERT 3, DELETE 4.
    static func operations(events: Int) -> PluginViewWriteOperations {
        var operations: PluginViewWriteOperations = []
        if events & 4 != 0 { operations.insert(.update) }
        if events & 8 != 0 { operations.insert(.insert) }
        if events & 16 != 0 { operations.insert(.delete) }
        return operations
    }

    static func baseAttributeNumbers(_ chain: [Relation]) -> [Int: Int] {
        let views = chain.prefix(while: \.isView)
        guard let outer = views.first else { return [:] }
        return views.dropFirst().reduce(outer.origins.mapValues(\.attributeNumber)) { numbers, view in
            numbers.compactMapValues { view.origins[$0]?.attributeNumber }
        }
    }

    static func resolve(
        chain: [Relation],
        viewColumns viewRows: [[String?]],
        baseColumns baseRows: [[String?]]
    ) -> PluginViewRowEditing {
        let attributes = baseRows.compactMap(BaseAttribute.init(row:))
        guard let outer = chain.first, let base = chain.last, !base.isView, !attributes.isEmpty else {
            return .readOnly(.notUpdatable)
        }
        // A target entry with no view attribute means the tree was misread, so no mapping is trusted.
        let viewNumbers = Set(viewRows.compactMap { cell($0, 0).flatMap(Int.init) })
        guard Set(outer.origins.keys).isSubset(of: viewNumbers) else { return .readOnly(.notUpdatable) }

        var baseNames: [Int: String] = [:]
        for attribute in attributes { baseNames[attribute.number] = attribute.column.name }
        let baseNumbers = baseAttributeNumbers(chain)
        let columns = viewRows.compactMap { row -> PluginViewColumn? in
            guard let number = cell(row, 0).flatMap(Int.init), let name = cell(row, 1) else { return nil }
            return PluginViewColumn(
                name: name,
                baseColumn: baseNumbers[number].flatMap { baseNames[$0] },
                acceptsWrites: PostgreSQLCatalogBoolean.isTrue(cell(row, 2))
            )
        }
        let keyColumns = attributes
            .compactMap { attribute in attribute.keyPosition.map { (position: $0, name: attribute.column.name) } }
            .sorted { $0.position < $1.position }
            .map(\.name)

        return PluginViewRowEditing.resolve(
            operations: operations(events: outer.events),
            baseTable: PluginViewBaseTable(schema: base.schema, name: base.name),
            columns: columns,
            baseKeyColumns: keyColumns,
            baseColumns: attributes.map(\.column)
        )
    }

    // A WHERE sub-select stores its own target list first, so only the outermost query's list is read.
    static func targetOrigins(nodeTree: String) -> [Int: ColumnOrigin] {
        let tokens = NodeTreeToken.tokenize(nodeTree)
        guard let queryIndex = tokens.firstIndex(where: { $0.text == "QUERY" }) else { return [:] }
        let queryDepth = tokens[queryIndex].depth
        guard let listIndex = tokens[queryIndex...].firstIndex(where: {
            $0.depth == queryDepth && $0.text == ":targetList"
        }) else { return [:] }

        let entryDepth = queryDepth + 2
        var origins: [Int: ColumnOrigin] = [:]
        var fields: [String: String] = [:]
        var index = tokens.index(after: listIndex)
        guard index < tokens.count, tokens[index].text == "(" else { return [:] }
        index += 1

        while index < tokens.count, tokens[index].depth > queryDepth {
            let token = tokens[index]
            if token.text == "}", token.depth == entryDepth - 1 {
                if let entry = origin(from: fields) { origins[entry.number] = entry.origin }
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

    private static func origin(from fields: [String: String]) -> (number: Int, origin: ColumnOrigin)? {
        guard fields[":resjunk"] != "true",
              let number = fields[":resno"].flatMap(Int.init),
              let table = fields[":resorigtbl"], table != "0",
              let column = fields[":resorigcol"].flatMap(Int.init), column > 0
        else { return nil }
        return (number, ColumnOrigin(relationOID: table, attributeNumber: column))
    }

    private struct BaseAttribute {
        let number: Int
        let column: PluginViewBaseColumn
        let keyPosition: Int?

        init?(row: [String?]) {
            guard let number = cell(row, 0).flatMap(Int.init), let name = cell(row, 1) else { return nil }
            let identity = cell(row, 4) ?? ""
            let generated = cell(row, 5) ?? ""
            self.number = number
            // pg_attrdef holds a generated column's expression too, which is no default.
            column = PluginViewBaseColumn(
                name: name,
                isNullable: !PostgreSQLCatalogBoolean.isTrue(cell(row, 2)),
                defaultValue: generated.isEmpty ? cell(row, 3) : nil,
                assignsValue: identity == "a" || identity == "d",
                acceptsWrites: generated.isEmpty && identity != "a"
            )
            keyPosition = cell(row, 6).flatMap(Int.init)
        }
    }
}

private func cell(_ row: [String?], _ index: Int) -> String? {
    row[safe: index] ?? nil
}

// depth counts the brackets open before a token; a closing bracket carries its opening one's depth.
private struct NodeTreeToken {
    let text: String
    let depth: Int

    var isBracket: Bool { ["{", "}", "(", ")"].contains(text) }

    static func tokenize(_ text: String) -> [NodeTreeToken] {
        var tokens: [NodeTreeToken] = []
        var depth = 0
        var word = String.UnicodeScalarView()
        var escaped = false

        func flush() {
            if !word.isEmpty { tokens.append(NodeTreeToken(text: String(word), depth: depth)) }
            word = String.UnicodeScalarView()
        }

        // Scalars, not Characters: a combining mark after a space or bracket would fuse the two into one Character.
        for character in text.unicodeScalars {
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
