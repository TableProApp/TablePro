//
//  MySQLTableOptions.swift
//  MySQLDriverPlugin
//
//  A table's character set, collation and AUTO_INCREMENT counter, the server's catalog of character
//  sets, collations and engines, and the ALTER TABLE that changes them.
//

import Foundation
import TableProMySQLCore
import TableProPluginKit

internal struct MySQLCharsetDefault: Equatable {
    let charset: String
    let defaultCollation: String
    let description: String?
}

internal struct MySQLCollationEntry: Equatable {
    let collation: String
    let charset: String
}

internal struct MySQLStorageEngine: Equatable {
    let name: String
    let isDefault: Bool
}

/// One `information_schema.TABLES` row as `MySQLTableOptions.tableQuery` reads it.
internal struct MySQLTableOptionsRow: Equatable {
    let type: String
    let collation: String?
    let autoIncrement: UInt64?
    let hasAutoIncrementColumn: Bool

    /// MariaDB 11.4 lists a session's temporary table as `TEMPORARY` beside the base table it hides.
    static func row(named table: String, in rows: [[PluginCellValue]]) -> MySQLTableOptionsRow? {
        let permanent = rows.filter { $0[safe: 1]?.asText?.uppercased() != "TEMPORARY" }
        guard let row = MySQLTableStatusRow.row(named: table, in: permanent),
              let type = row[safe: 1]?.asText
        else { return nil }
        return MySQLTableOptionsRow(
            type: type.uppercased(),
            collation: row[safe: 2]?.asText?.nilIfEmpty,
            autoIncrement: row[safe: 3]?.asText.flatMap { UInt64($0) },
            hasAutoIncrementColumn: (row[safe: 4]?.asText.flatMap { Int($0) } ?? 0) > 0
        )
    }

    // A view fails ALTER TABLE with ERROR 1347, and a sequence has no text column or counter.
    var takesTableOptions: Bool {
        type == "BASE TABLE" || type == "SYSTEM VERSIONED"
    }
}

internal enum MySQLTableOptions {
    // TiDB needs FORCE to lower the counter and OceanBase is unmeasured, so both read the catalog only.
    static func writesOptions(flavor: MySQLServerFlavor) -> Bool {
        flavor == .mysql || flavor == .mariadb
    }

    static func readsCatalog(flavor: MySQLServerFlavor) -> Bool {
        flavor.hasMySQLObjectCatalogs
    }

    /// A default change leaves existing columns on their own character set; a convert rewrites every text
    /// column. Clauses join with commas, so one statement carries either one with the counter.
    static func statement(qualifiedTable: String, change: PluginTableOptionsChange) -> String? {
        let characterSet = change.characterSet?.nilIfEmpty.map(mysqlCharsetName)
        let collation = change.collation?.nilIfEmpty.map(mysqlCharsetName)
        var clauses: [String] = []
        if change.convertsColumns {
            guard let characterSet else { return nil }
            clauses.append("CONVERT TO CHARACTER SET \(characterSet)" + (collation.map { " COLLATE \($0)" } ?? ""))
        } else if characterSet != nil || collation != nil {
            let parts = [
                characterSet.map { "DEFAULT CHARACTER SET = \($0)" },
                collation.map { "COLLATE = \($0)" }
            ]
            clauses.append(parts.compactMap { $0 }.joined(separator: " "))
        }
        if let autoIncrement = change.autoIncrement {
            clauses.append("AUTO_INCREMENT = \(autoIncrement)")
        }
        guard !clauses.isEmpty else { return nil }
        return "ALTER TABLE \(qualifiedTable) \(clauses.joined(separator: ", "))"
    }

    /// `TABLE_COLLATION` changes the moment an ALTER does, unlike the statistics columns. The column count
    /// compares names as bytes, because the catalog collates them case-insensitively.
    static func tableQuery(schema: String, table: String) -> String {
        let schemaLiteral = mysqlEscapeStringLiteral(schema)
        let tableLiteral = mysqlEscapeStringLiteral(table)
        return """
            SELECT t.TABLE_NAME, t.TABLE_TYPE, t.TABLE_COLLATION, t.AUTO_INCREMENT,
                (SELECT COUNT(*) FROM information_schema.COLUMNS c
                    WHERE c.TABLE_SCHEMA = '\(schemaLiteral)' AND c.TABLE_NAME = '\(tableLiteral)'
                        AND CAST(c.TABLE_NAME AS BINARY) = CAST(t.TABLE_NAME AS BINARY)
                        AND c.EXTRA LIKE '%auto_increment%')
            FROM information_schema.TABLES t
            WHERE t.TABLE_SCHEMA = '\(schemaLiteral)' AND t.TABLE_NAME = '\(tableLiteral)'
            """
    }

    static func schemaDefaultsQuery(schema: String) -> String {
        """
        SELECT SCHEMA_NAME, DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME
        FROM information_schema.SCHEMATA
        WHERE SCHEMA_NAME = '\(mysqlEscapeStringLiteral(schema))'
        """
    }

    /// No character set name holds an underscore, so a collation's prefix names its character set. MariaDB
    /// 10.10+ reports the full `utf8mb4_uca1400_ai_ci`, which `COLLATIONS` does not list.
    static func characterSet(ofCollation collation: String?) -> String? {
        guard let collation = collation?.nilIfEmpty else { return nil }
        return collation.split(separator: "_", maxSplits: 1).first.map(String.init)
    }

    /// The value the next row takes. MySQL 8 caches `TABLES.AUTO_INCREMENT` for up to a day, so it reads
    /// the `SHOW CREATE TABLE` options, which omit the clause when the next value is 1. An options line
    /// without `ENGINE=` was printed under `NO_TABLE_OPTIONS` and says nothing, so the catalog answers.
    static func counter(
        row: MySQLTableOptionsRow,
        createTableOptions: [String: String]?
    ) -> UInt64? {
        guard row.hasAutoIncrementColumn else { return nil }
        if let options = createTableOptions, options["ENGINE"] != nil {
            return options["AUTO_INCREMENT"].flatMap { UInt64($0) } ?? 1
        }
        return row.autoIncrement ?? 1
    }

    static func tableOptions(row: MySQLTableOptionsRow, createTableOptions: [String: String]?) -> PluginTableOptions? {
        guard row.takesTableOptions else { return nil }
        return PluginTableOptions(
            characterSet: characterSet(ofCollation: row.collation),
            collation: row.collation,
            autoIncrement: counter(row: row, createTableOptions: createTableOptions)
        )
    }

    static func schemaDefaults(named schema: String, in rows: [[PluginCellValue]]) -> PluginTableOptions? {
        guard let row = MySQLTableStatusRow.row(named: schema, in: rows) ?? (rows.count == 1 ? rows.first : nil)
        else { return nil }
        let collation = row[safe: 2]?.asText?.nilIfEmpty
        let characterSet = row[safe: 1]?.asText?.nilIfEmpty ?? characterSet(ofCollation: collation)
        guard characterSet != nil || collation != nil else { return nil }
        return PluginTableOptions(characterSet: characterSet, collation: collation)
    }

    static func engines(fromRows rows: [[PluginCellValue]]) -> [MySQLStorageEngine] {
        rows.compactMap { row -> MySQLStorageEngine? in
            guard let name = row[safe: 0]?.asText?.nilIfEmpty,
                  let support = row[safe: 1]?.asText?.uppercased(),
                  support == "YES" || support == "DEFAULT"
            else { return nil }
            return MySQLStorageEngine(name: name, isDefault: support == "DEFAULT")
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Each character set with the collations listed for it, its default always among them.
    static func catalog(
        characterSets: [MySQLCharsetDefault],
        collations: [MySQLCollationEntry],
        engines: [MySQLStorageEngine]
    ) -> PluginTableOptionsCatalog {
        let collationsByCharset = Dictionary(grouping: collations, by: \.charset)
        let sets = characterSets.map { entry -> PluginCharacterSet in
            var names = Set((collationsByCharset[entry.charset] ?? []).map(\.collation))
            names.insert(entry.defaultCollation)
            return PluginCharacterSet(
                name: entry.charset,
                defaultCollation: entry.defaultCollation,
                collations: names.sorted(),
                description: entry.description
            )
        }
        return PluginTableOptionsCatalog(
            characterSets: sets,
            engines: engines.map(\.name),
            defaultEngine: engines.first(where: \.isDefault)?.name
        )
    }
}
