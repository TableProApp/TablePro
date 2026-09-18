import Foundation

public enum SpannerCatalogParser {
    public static func schemas(_ rows: [[SpannerCell]], dialect: SpannerDialect) -> [String] {
        rows.compactMap { row in
            guard let name = row.text(at: 0), !dialect.isSystemSchema(name) else { return nil }
            return name
        }
    }

    public static func tables(_ rows: [[SpannerCell]]) -> [SpannerTableInfo] {
        rows.compactMap { row in
            guard let schema = row.text(at: 0), let name = row.text(at: 1) else { return nil }
            return SpannerTableInfo(schema: schema, name: name, isView: row.text(at: 2)?.uppercased() == "VIEW")
        }
    }

    public static func columns(_ rows: [[SpannerCell]]) -> [SpannerColumnInfo] {
        rows.compactMap { row in
            guard let schema = row.text(at: 0), let table = row.text(at: 1), let name = row.text(at: 2) else { return nil }
            return SpannerColumnInfo(
                schema: schema,
                table: table,
                name: name,
                spannerType: row.text(at: 3) ?? "",
                isNullable: row.flag(at: 4),
                isPrimaryKey: row.text(at: 12) != nil,
                defaultExpression: row.text(at: 5),
                isGenerated: row.text(at: 6)?.uppercased() == "ALWAYS",
                generationExpression: row.text(at: 7),
                isStored: row.flag(at: 8),
                identityGeneration: row.flag(at: 9) ? row.text(at: 10) : nil,
                isHidden: row.flag(at: 11)
            )
        }
    }

    public static func indexes(_ rows: [[SpannerCell]]) -> [SpannerIndexInfo] {
        var groups = SpannerOrderedGroups<SpannerIndexGroup>()
        for row in rows {
            guard let schema = row.text(at: 0), let table = row.text(at: 1), let name = row.text(at: 2),
                  let column = row.text(at: 6), let ordinal = row.text(at: 7).flatMap({ Int($0) })
            else {
                continue
            }
            let key = [schema, table, name]
            groups.update(key, create: {
                SpannerIndexGroup(
                    schema: schema,
                    table: table,
                    name: name,
                    type: row.text(at: 3) ?? "",
                    isUnique: row.flag(at: 4),
                    isManaged: row.flag(at: 5)
                )
            }, mutate: { $0.columns.append((ordinal, column)) })
        }
        return groups.values.map(\.info)
    }

    public static func foreignKeys(_ rows: [[SpannerCell]], interleaveRows: [[SpannerCell]]) -> [SpannerForeignKeyInfo] {
        constraintForeignKeys(rows) + interleaveForeignKeys(interleaveRows)
    }

    public static func viewDefinition(_ rows: [[SpannerCell]]) -> String? {
        rows.first?.text(at: 0)
    }

    private static func constraintForeignKeys(_ rows: [[SpannerCell]]) -> [SpannerForeignKeyInfo] {
        var groups = SpannerOrderedGroups<SpannerForeignKeyGroup>()
        for row in rows {
            guard let schema = row.text(at: 0), let table = row.text(at: 1), let name = row.text(at: 2),
                  let column = row.text(at: 3), let referencedSchema = row.text(at: 4),
                  let referencedTable = row.text(at: 5), let referencedColumn = row.text(at: 6)
            else {
                continue
            }
            groups.update([schema, table, name], create: {
                SpannerForeignKeyGroup(
                    schema: schema,
                    table: table,
                    name: name,
                    referencedSchema: referencedSchema,
                    referencedTable: referencedTable,
                    onDelete: row.text(at: 7),
                    isInterleave: false
                )
            }, mutate: {
                $0.columns.append(column)
                $0.referencedColumns.append(referencedColumn)
            })
        }
        return groups.values.map(\.info)
    }

    private static func interleaveForeignKeys(_ rows: [[SpannerCell]]) -> [SpannerForeignKeyInfo] {
        var groups = SpannerOrderedGroups<SpannerForeignKeyGroup>()
        for row in rows {
            guard let schema = row.text(at: 0), let table = row.text(at: 1), let parent = row.text(at: 2),
                  let column = row.text(at: 5)
            else {
                continue
            }
            groups.update([schema, table], create: {
                SpannerForeignKeyGroup(
                    schema: schema,
                    table: table,
                    name: interleaveName(parent: parent, interleaveType: row.text(at: 4)),
                    referencedSchema: schema,
                    referencedTable: parent,
                    onDelete: row.text(at: 3),
                    isInterleave: true
                )
            }, mutate: {
                $0.columns.append(column)
                $0.referencedColumns.append(column)
            })
        }
        return groups.values.map(\.info)
    }

    private static func interleaveName(parent: String, interleaveType: String?) -> String {
        interleaveType?.uppercased() == "IN" ? "INTERLEAVE IN \(parent)" : "INTERLEAVE IN PARENT \(parent)"
    }
}

private struct SpannerIndexGroup {
    let schema: String
    let table: String
    let name: String
    let type: String
    let isUnique: Bool
    let isManaged: Bool
    var columns: [(ordinal: Int, name: String)] = []

    var info: SpannerIndexInfo {
        SpannerIndexInfo(
            schema: schema,
            table: table,
            name: name,
            columns: columns.sorted { $0.ordinal < $1.ordinal }.map(\.name),
            isUnique: isUnique,
            isPrimaryKey: type.uppercased() == "PRIMARY_KEY",
            isManaged: isManaged,
            type: type
        )
    }
}

private struct SpannerForeignKeyGroup {
    let schema: String
    let table: String
    let name: String
    let referencedSchema: String
    let referencedTable: String
    let onDelete: String?
    let isInterleave: Bool
    var columns: [String] = []
    var referencedColumns: [String] = []

    var info: SpannerForeignKeyInfo {
        SpannerForeignKeyInfo(
            schema: schema,
            table: table,
            name: name,
            columns: columns,
            referencedSchema: referencedSchema,
            referencedTable: referencedTable,
            referencedColumns: referencedColumns,
            onDelete: onDelete,
            isInterleave: isInterleave
        )
    }
}

private struct SpannerOrderedGroups<Group> {
    private var order: [[String]] = []
    private var groups: [[String]: Group] = [:]

    var values: [Group] {
        order.compactMap { groups[$0] }
    }

    mutating func update(_ key: [String], create: () -> Group, mutate: (inout Group) -> Void) {
        if groups[key] == nil {
            order.append(key)
            groups[key] = create()
        }
        guard var group = groups[key] else { return }
        mutate(&group)
        groups[key] = group
    }
}

private extension Array where Element == SpannerCell {
    func text(at index: Int) -> String? {
        guard index < count else { return nil }
        switch self[index] {
        case .text(let value):
            return value
        case .bytes(let data):
            return String(data: data, encoding: .utf8)
        case .null:
            return nil
        }
    }

    func flag(at index: Int) -> Bool {
        guard let value = text(at: index)?.uppercased() else { return false }
        return value == "YES" || value == "TRUE"
    }
}
