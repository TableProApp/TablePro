//
//  SQLiteForeignKeyGrouping.swift
//  TableProPluginKit
//

import Foundation

// PRAGMA foreign_key_list reports no constraint name, so the name comes from the stored CREATE TABLE.
// The pragma numbers keys in reverse declaration order and renumbers them on every change, so the two
// are matched on what each key describes, not on position.
public enum SQLiteForeignKeyGrouping {
    private struct Group {
        let id: String
        var columns: [String] = []
        var referencedColumns: [String] = []
        var referencedTable = ""
        var onUpdate = "NO ACTION"
        var onDelete = "NO ACTION"
    }

    // Rows: PRAGMA foreign_key_list's columns, then the table's DDL on the first row only. The pragma itself
    // finds the table, so a temporary table keeps its keys.
    public static func foreignKeysQuery(table: String) -> String {
        foreignKeysQuery(table: table, schema: nil)
    }

    // A key in an attached database can only reference a table in that same database, so the parent's
    // primary key is read from there too.
    public static func foreignKeysQuery(table: String, schema: String?) -> String {
        let literal = "'\(SQLiteMasterQueries.escapeLiteral(table))'"
        let inSchema = SQLiteMasterQueries.pragmaSchemaArgument(schema)
        return """
            SELECT \(pragmaColumns(schema: schema)),
                   CASE WHEN p.id = 0 AND p.seq = 0 THEN (
                       SELECT sql FROM \(SQLiteMasterQueries.catalogTable(schema: schema))
                       WHERE type = 'table' AND name = \(literal) COLLATE NOCASE
                   ) END
            FROM pragma_foreign_key_list(\(literal)\(inSchema)) p
            ORDER BY p.id, p.seq
            """
    }

    // The same rows behind the table's name. GLOB, not LIKE: `_` is a LIKE wildcard, so LIKE 'sqlite_%' also
    // hides a user table like sqlitebrowser_x.
    public static func schemaForeignKeysQuery(excludingTableGlob glob: String? = nil) -> String {
        schemaForeignKeysQuery(schema: nil, excludingTableGlob: glob)
    }

    public static func schemaForeignKeysQuery(schema: String?, excludingTableGlob glob: String?) -> String {
        let excluded = glob.map { " AND m.name NOT GLOB '\(SQLiteMasterQueries.escapeLiteral($0))'" } ?? ""
        let inSchema = SQLiteMasterQueries.pragmaSchemaArgument(schema)
        return """
            SELECT m.name, \(pragmaColumns(schema: schema)), CASE WHEN p.id = 0 AND p.seq = 0 THEN m.sql END
            FROM \(SQLiteMasterQueries.catalogTable(schema: schema)) m, pragma_foreign_key_list(m.name\(inSchema)) p
            WHERE m.type = 'table' AND m.name NOT GLOB 'sqlite_*'\(excluded)
            ORDER BY m.name, p.id, p.seq
            """
    }

    // `to` is null for a shorthand `REFERENCES parent`. pragma_table_info finds the parent by SQLite's own
    // name rule, which folds ASCII case only, unlike Swift's lowercased().
    private static func pragmaColumns(schema: String?) -> String {
        """
        p.id, p.seq, p."table", p."from",
               ifnull(p."to", (SELECT k.name FROM pragma_table_info(p."table"\(SQLiteMasterQueries.pragmaSchemaArgument(schema))) k
                               WHERE k.pk = p.seq + 1)),
               p.on_update, p.on_delete, p."match"
        """
    }

    public static func foreignKeys(table: String, fromRows rows: [[PluginCellValue]]) -> [PluginForeignKeyInfo] {
        foreignKeys(table: table, schema: nil, fromRows: rows)
    }

    /// A key read from an attached database names that database as the referenced table's schema, so a
    /// jump to the parent row lands in the attached database and not in a same-named table of the main one.
    public static func foreignKeys(table: String, schema: String?, fromRows rows: [[PluginCellValue]]) -> [PluginForeignKeyInfo] {
        let listed = rows.filter { $0.count >= 9 }
        let keys = infos(
            table: table,
            pragmaRows: listed.map { Array($0.prefix(8)) },
            createTableSQL: listed.lazy.compactMap { $0[8].asText }.first
        )
        guard let attached = SQLiteMasterQueries.attachedSchema(schema) else { return keys }
        return keys.map {
            PluginForeignKeyInfo(
                name: $0.name,
                column: $0.column,
                referencedTable: $0.referencedTable,
                referencedColumn: $0.referencedColumn,
                referencedDatabase: nil,
                referencedSchema: attached,
                onDelete: $0.onDelete,
                onUpdate: $0.onUpdate
            )
        }
    }

    public static func foreignKeysByTable(fromRows rows: [[PluginCellValue]]) -> [String: [PluginForeignKeyInfo]] {
        foreignKeysByTable(schema: nil, fromRows: rows)
    }

    public static func foreignKeysByTable(schema: String?, fromRows rows: [[PluginCellValue]]) -> [String: [PluginForeignKeyInfo]] {
        var rowsByTable: [String: [[PluginCellValue]]] = [:]
        for row in rows {
            guard row.count >= 10, let table = row[0].asText else { continue }
            rowsByTable[table, default: []].append(Array(row.dropFirst()))
        }
        return rowsByTable.reduce(into: [:]) { result, entry in
            result[entry.key] = foreignKeys(table: entry.key, schema: schema, fromRows: entry.value)
        }
    }

    // pragmaRows: id | seq | table | from | to | on_update | on_delete | match. A composite key comes back
    // as one info per column pair under one name, which is how the schema editor regroups it.
    public static func infos(
        table: String,
        pragmaRows: [[PluginCellValue]],
        createTableSQL: String?,
        primaryKeysByTable: [String: [String]] = [:]
    ) -> [PluginForeignKeyInfo] {
        let groups = groups(from: pragmaRows, primaryKeysByTable: primaryKeysByTable)
        let names = resolvedNames(for: groups, table: table, createTableSQL: createTableSQL)

        return zip(groups, names).flatMap { group, name -> [PluginForeignKeyInfo] in
            zip(group.columns, group.referencedColumns).map { column, referencedColumn in
                PluginForeignKeyInfo(
                    name: name,
                    column: column,
                    referencedTable: group.referencedTable,
                    referencedColumn: referencedColumn,
                    onDelete: group.onDelete,
                    onUpdate: group.onUpdate
                )
            }
        }
    }

    private static func groups(
        from rows: [[PluginCellValue]],
        primaryKeysByTable: [String: [String]]
    ) -> [Group] {
        var groups: [Group] = []
        var indexByID: [String: Int] = [:]

        for row in rows {
            guard row.count >= 5,
                  let referencedTable = row[safe: 2]?.asText,
                  let column = row[safe: 3]?.asText else { continue }
            let id = row[safe: 0]?.asText ?? "0"

            let index: Int
            if let existing = indexByID[id] {
                index = existing
            } else {
                index = groups.count
                indexByID[id] = index
                groups.append(Group(id: id))
            }

            groups[index].referencedTable = referencedTable
            groups[index].columns.append(column)
            // `to` is null for a shorthand `REFERENCES parent`, which means the parent's primary key.
            let parentKey = primaryKeysByTable[referencedTable.lowercased()] ?? []
            let position = groups[index].columns.count - 1
            groups[index].referencedColumns.append(
                row[safe: 4]?.asText ?? parentKey[safe: position] ?? column
            )
            if let onUpdate = row[safe: 5]?.asText { groups[index].onUpdate = onUpdate }
            if let onDelete = row[safe: 6]?.asText { groups[index].onDelete = onDelete }
        }
        return groups
    }

    // Consumers group rows by name, so two keys sharing one would show as one composite key. A declared
    // name is kept when no other key declares it; every other key takes fk_<table>_<id>, suffixed until
    // no other key uses it, since a declared name may spell another key's positional one.
    private static func resolvedNames(
        for groups: [Group],
        table: String,
        createTableSQL: String?
    ) -> [String] {
        let declared = declaredNames(for: groups, createTableSQL: createTableSQL)
        var occurrences: [String: Int] = [:]
        for name in declared.compactMap({ $0 }) {
            occurrences[name, default: 0] += 1
        }
        let kept = declared.map { name in name.flatMap { occurrences[$0] == 1 ? $0 : nil } }
        var used = Set(kept.compactMap { $0 })

        return zip(groups, kept).map { group, name in
            if let name { return name }
            let positional = "fk_\(table)_\(group.id)"
            var candidate = positional
            var suffix = 2
            while !used.insert(candidate).inserted {
                candidate = "\(positional)_\(suffix)"
                suffix += 1
            }
            return candidate
        }
    }

    // A clause names the one group it can describe. The pragma lists keys in reverse declaration order, so
    // a clause that fits several groups is settled only once the others are taken, and keys that stay
    // indistinguishable keep positional names rather than risk a swap.
    private static func declaredNames(for groups: [Group], createTableSQL: String?) -> [String?] {
        guard let createTableSQL,
              let parsed = SQLiteTableDDL.parse(createTableSQL: createTableSQL) else {
            return Array(repeating: nil, count: groups.count)
        }
        let clauses = SQLiteTableDDL.foreignKeys(in: parsed)
        var candidates = clauses.map { clause in
            Set(groups.indices.filter { describes(clause, groups[$0]) })
        }
        var names = [String?](repeating: nil, count: groups.count)
        while let index = candidates.firstIndex(where: { $0.count == 1 }), let group = candidates[index].first {
            if let name = clauses[index].name, !name.isEmpty {
                names[group] = name
            }
            for other in candidates.indices {
                candidates[other].remove(group)
            }
        }
        return names
    }

    // A shorthand `REFERENCES parent` names no parent columns while the group holds them resolved, so they
    // are compared only when the DDL gives them. An omitted action reads back from the pragma as NO ACTION.
    private static func describes(_ clause: SQLiteForeignKeyClause, _ group: Group) -> Bool {
        sameIdentifiers(clause.columns, group.columns)
            && sameIdentifier(clause.referencedTable, group.referencedTable)
            && (clause.referencedColumns.isEmpty || sameIdentifiers(clause.referencedColumns, group.referencedColumns))
            && sameIdentifier(clause.onDelete ?? "NO ACTION", group.onDelete)
            && sameIdentifier(clause.onUpdate ?? "NO ACTION", group.onUpdate)
    }

    private static func sameIdentifier(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .caseInsensitive) == .orderedSame
    }

    private static func sameIdentifiers(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy(sameIdentifier)
    }
}
