import Foundation

// The valid indexes of one table, from PostgreSQLTableHealthProvider.redundantIndexQuery: a row per index column,
// key columns first, then the INCLUDE columns.
struct PostgreSQLIndexShape {
    // A key column by name, or an expression by its node text, with what decides which lookups it serves.
    struct KeyPart: Equatable {
        let column: String
        let isExpression: Bool
        let operatorClass: String
        let collation: String
        let sortOption: String

        var displayName: String {
            isExpression ? String(localized: "(expression)") : column
        }
    }

    struct Index {
        let name: String
        let accessMethod: String
        let isUnique: Bool
        let isPrimary: Bool
        let isImmediate: Bool
        let nullsNotDistinct: Bool
        // Backs a constraint, belongs to a partitioned index or is the replica identity: dropping it alone fails or
        // changes what the table does.
        let isProtected: Bool
        let predicate: String?
        let sizeBytes: Int64?
        var keys: [KeyPart]
        var includes: [String]

        var columns: [String] { keys.map(\.column) + includes }

        // The key columns, expressions as a placeholder, then any INCLUDE columns.
        var columnsDescription: String {
            let keyList = keys.map(\.displayName).joined(separator: ", ")
            guard !includes.isEmpty else { return keyList }
            return String(format: String(localized: "%1$@ INCLUDE (%2$@)"), keyList, includes.joined(separator: ", "))
        }

        // Only a B-tree serves a lookup on its leading keys, so another method is redundant only to an equal index.
        // A unique index is redundant only to one enforcing the same rule. Of two indexes that cover each other, a
        // protected one stays, else the earlier name.
        func isRedundant(to other: Index) -> Bool {
            guard other.name != name, !isProtected, !isPrimary,
                  other.accessMethod == accessMethod, other.predicate == predicate,
                  keys.count <= other.keys.count,
                  accessMethod == "btree" || keys.count == other.keys.count,
                  Array(other.keys.prefix(keys.count)) == keys,
                  Set(includes).isSubset(of: other.columns)
            else { return false }
            if isUnique {
                guard other.isUnique, keys.count == other.keys.count,
                      isImmediate == other.isImmediate, nullsNotDistinct == other.nullsNotDistinct
                else { return false }
            }
            let mutual = keys.count == other.keys.count && isUnique == other.isUnique
                && Set(other.includes).isSubset(of: columns)
            return !mutual || other.isProtected || other.isPrimary || other.name < name
        }

        // Which of several covering indexes a finding names: the one least likely to be dropped itself.
        func outranks(_ other: Index) -> Bool {
            if isPrimary != other.isPrimary { return isPrimary }
            if isProtected != other.isProtected { return isProtected }
            if isUnique != other.isUnique { return isUnique }
            if keys.count != other.keys.count { return keys.count > other.keys.count }
            if columns.count != other.columns.count { return columns.count > other.columns.count }
            return name < other.name
        }
    }

    let schema: String
    let table: String
    let isPartitioned: Bool
    var indexes: [Index]

    var redundantIndexes: [(index: Index, coveredBy: Index)] {
        indexes.compactMap { index in
            indexes.filter { index.isRedundant(to: $0) }
                .min { $0.outranks($1) }
                .map { (index: index, coveredBy: $0) }
        }
    }

    // Grouped by exact names and ordered by position, so the grouping never depends on the row order.
    static func tables(from rows: [TableHealthRow]) -> [PostgreSQLIndexShape] {
        var tables: [PostgreSQLIndexShape] = []
        var tablePositions: [[String]: Int] = [:]
        var parts: [[String]: [(position: Int, keyCount: Int, row: TableHealthRow)]] = [:]
        for row in rows {
            let tableKey = [row["schema_name"], row["table_name"]]
            let tablePosition: Int
            if let known = tablePositions[tableKey] {
                tablePosition = known
            } else {
                tablePosition = tables.count
                tablePositions[tableKey] = tablePosition
                tables.append(PostgreSQLIndexShape(
                    schema: row["schema_name"], table: row["table_name"], isPartitioned: row["table_kind"] == "p", indexes: []
                ))
            }
            let indexName = row["index_name"]
            if !tables[tablePosition].indexes.contains(where: { $0.name == indexName }) {
                tables[tablePosition].indexes.append(Index(
                    name: indexName,
                    accessMethod: row["access_method"],
                    isUnique: row.flag("is_unique") == true,
                    isPrimary: row.flag("is_primary") == true,
                    isImmediate: row.flag("is_immediate") != false,
                    nullsNotDistinct: row.flag("nulls_not_distinct") == true,
                    isProtected: row.flag("is_protected") == true,
                    predicate: row.text("predicate"),
                    sizeBytes: row.int64("index_bytes"),
                    keys: [],
                    includes: []
                ))
            }
            parts[tableKey + [indexName], default: []].append((
                Int(row.int64("position") ?? 0), Int(row.int64("key_count") ?? 0), row
            ))
        }
        for tablePosition in tables.indices {
            let tableKey = [tables[tablePosition].schema, tables[tablePosition].table]
            for indexPosition in tables[tablePosition].indexes.indices {
                let indexParts = (parts[tableKey + [tables[tablePosition].indexes[indexPosition].name]] ?? [])
                    .sorted { $0.position < $1.position }
                var index = tables[tablePosition].indexes[indexPosition]
                // indexprs holds one expression per zero in indkey, in key order.
                var expressions = indexParts.lazy.compactMap { $0.row.text("expressions") }.first.map(Self.expressions) ?? []
                for part in indexParts {
                    let isExpression = part.row.int64("attnum") == 0
                    let column = isExpression
                        ? (expressions.isEmpty ? "" : expressions.removeFirst())
                        : part.row["column_name"]
                    if part.position <= part.keyCount {
                        index.keys.append(KeyPart(
                            column: column,
                            isExpression: isExpression,
                            operatorClass: part.row["opclass"],
                            collation: part.row["collation"],
                            sortOption: part.row["sort_option"]
                        ))
                    } else {
                        index.includes.append(column)
                    }
                }
                tables[tablePosition].indexes[indexPosition] = index
            }
        }
        return tables
    }

    // The top-level nodes of a node-tree list, "({A ...} {B ...})". The server escapes a brace inside a token with a
    // backslash, so an escaped character never opens or closes a node.
    static func expressions(_ list: String) -> [String] {
        var nodes: [String] = []
        var current = ""
        var depth = 0
        var escaped = false
        for character in list {
            if escaped {
                if depth > 0 { current.append(character) }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                if depth > 0 { current.append(character) }
                continue
            }
            if character == "{" { depth += 1 }
            if depth > 0 { current.append(character) }
            if character == "}", depth > 0 {
                depth -= 1
                if depth == 0 {
                    nodes.append(current)
                    current = ""
                }
            }
        }
        return nodes
    }
}
