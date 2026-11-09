import Foundation

// The valid indexes of one table, from PostgreSQLTableHealthProvider.redundantIndexQuery: a row per index column,
// key columns first, then the INCLUDE columns.
struct PostgreSQLIndexShape {
    // A key column or expression as the server deparses it, with what decides which lookups it serves.
    struct KeyPart: Equatable {
        let column: String
        let operatorClass: String
        let collation: String
        let sortOption: String
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
        var definition: String?
        var keys: [KeyPart]
        var includes: [String]

        var columns: [String] { keys.map(\.column) + includes }

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
                    definition: nil,
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
                for part in indexParts {
                    if index.definition == nil { index.definition = part.row.text("index_definition") }
                    if part.position <= part.keyCount {
                        index.keys.append(KeyPart(
                            column: part.row["column_text"],
                            operatorClass: part.row["opclass"],
                            collation: part.row["collation"],
                            sortOption: part.row["sort_option"]
                        ))
                    } else {
                        index.includes.append(part.row["column_text"])
                    }
                }
                tables[tablePosition].indexes[indexPosition] = index
            }
        }
        return tables
    }
}
