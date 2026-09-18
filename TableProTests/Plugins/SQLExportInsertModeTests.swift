//
//  SQLExportInsertModeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("SQL export insert modes")
struct SQLExportInsertModeTests {

    private func renderer(_ dialect: SqlDialect) -> SQLExportInsertRenderer {
        SQLExportInsertRenderer(dialect: dialect) { "`\($0)`" }
    }

    private func render(
        _ dialect: SqlDialect,
        _ mode: SQLExportInsertMode,
        columns: [String] = ["id", "name", "email"],
        primaryKeys: [String] = ["id"]
    ) -> SQLExportInsertRenderer.Rendered {
        renderer(dialect).render(
            mode: mode,
            tableRef: "`users`",
            quotedColumns: "`id`, `name`, `email`",
            overriding: "",
            columnNames: columns,
            primaryKeyColumns: primaryKeys
        )
    }

    @Test("A plain insert is the same statement on every dialect")
    func plainInsertIsDialectIndependent() {
        for dialect in SqlDialect.allCases {
            let rendered = render(dialect, .insert)
            #expect(rendered.prefix == "INSERT INTO `users` (`id`, `name`, `email`) VALUES\n")
            #expect(rendered.suffix.isEmpty)
            #expect(rendered.warning == nil)
        }
    }

    /// The three dialects put conflict handling in three different places: MySQL in the verb,
    /// SQLite in a resolution clause, PostgreSQL in a trailing clause.
    @Test("Skipping existing rows uses each dialect's own spelling")
    func ignoreUsesDialectSpelling() {
        #expect(render(.mysql, .ignoreExisting).prefix.hasPrefix("INSERT IGNORE INTO"))
        #expect(render(.sqlite, .ignoreExisting).prefix.hasPrefix("INSERT OR IGNORE INTO"))

        let postgres = render(.postgres, .ignoreExisting)
        #expect(postgres.prefix.hasPrefix("INSERT INTO"))
        #expect(postgres.suffix == "\nON CONFLICT DO NOTHING")
    }

    @Test("Replacing uses REPLACE on MySQL and INSERT OR REPLACE on SQLite")
    func replaceUsesDialectSpelling() {
        #expect(render(.mysql, .replaceExisting).prefix.hasPrefix("REPLACE INTO"))
        #expect(render(.sqlite, .replaceExisting).prefix.hasPrefix("INSERT OR REPLACE INTO"))
    }

    /// PostgreSQL has no REPLACE, so it renders the upsert that overwrites every non-key column.
    @Test("Replacing on PostgreSQL renders as an upsert")
    func replaceOnPostgresIsAnUpsert() {
        let rendered = render(.postgres, .replaceExisting)
        #expect(rendered.suffix.contains("ON CONFLICT (`id`) DO UPDATE SET"))
        #expect(rendered.warning == nil)
    }

    @Test("Updating on MySQL assigns from VALUES and skips the key")
    func mysqlUpsertSkipsTheKey() {
        let rendered = render(.mysql, .updateExisting)
        #expect(rendered.suffix == "\nON DUPLICATE KEY UPDATE `name` = VALUES(`name`), `email` = VALUES(`email`)")
        #expect(!rendered.suffix.contains("`id` = VALUES"))
    }

    @Test("Updating on PostgreSQL names the conflict target and assigns from EXCLUDED")
    func postgresUpsertNamesTheTarget() {
        let rendered = render(.postgres, .updateExisting)
        #expect(rendered.suffix == "\nON CONFLICT (`id`) DO UPDATE SET `name` = EXCLUDED.`name`, `email` = EXCLUDED.`email`")
    }

    /// SQLite spells the pseudo-table `excluded` in lower case, and it is not case-insensitive there.
    @Test("Updating on SQLite uses the lower-case excluded pseudo-table")
    func sqliteUpsertUsesLowerCaseExcluded() {
        let rendered = render(.sqlite, .updateExisting)
        #expect(rendered.suffix.contains("excluded.`name`"))
        #expect(!rendered.suffix.contains("EXCLUDED."))
    }

    @Test("A composite key lists every key column as the conflict target")
    func compositeKeyNamesEveryColumn() {
        let rendered = render(
            .postgres, .updateExisting,
            columns: ["tenant", "id", "name"], primaryKeys: ["tenant", "id"])
        #expect(rendered.suffix.hasPrefix("\nON CONFLICT (`tenant`, `id`) DO UPDATE SET"))
        #expect(rendered.suffix.contains("`name` = EXCLUDED.`name`"))
    }

    /// Without a key there is no conflict target, so the statement would not parse. Writing plain
    /// inserts and warning beats writing a dump that fails on restore.
    @Test("A table with no primary key falls back to a plain insert and warns")
    func noPrimaryKeyFallsBack() {
        let rendered = render(.postgres, .updateExisting, primaryKeys: [])
        #expect(rendered.suffix.isEmpty)
        #expect(rendered.warning != nil)
    }

    @Test("A table whose columns are all key columns has nothing to update")
    func allKeyColumnsFallsBack() {
        let mysql = render(.mysql, .updateExisting, columns: ["id"], primaryKeys: ["id"])
        #expect(mysql.suffix.isEmpty)
        #expect(mysql.warning != nil)

        let postgres = render(.postgres, .updateExisting, columns: ["id"], primaryKeys: ["id"])
        #expect(postgres.suffix == "\nON CONFLICT DO NOTHING")
    }

    @Test("An engine with no conflict spelling writes plain inserts and warns")
    func genericDialectWarns() {
        for mode in [SQLExportInsertMode.ignoreExisting, .replaceExisting, .updateExisting] {
            let rendered = render(.generic, mode)
            #expect(rendered.prefix.hasPrefix("INSERT INTO"), "\(mode) should fall back")
            #expect(rendered.suffix.isEmpty)
            #expect(rendered.warning != nil, "\(mode) should warn")
        }
    }

    @Test("The OVERRIDING clause survives every mode that keeps a plain prefix")
    func overridingSurvives() {
        let rendered = SQLExportInsertRenderer(dialect: .postgres) { "\"\($0)\"" }.render(
            mode: .ignoreExisting,
            tableRef: "\"users\"",
            quotedColumns: "\"id\"",
            overriding: " OVERRIDING SYSTEM VALUE",
            columnNames: ["id"],
            primaryKeyColumns: ["id"]
        )
        #expect(rendered.prefix.contains(" OVERRIDING SYSTEM VALUE"))
    }
}

@Suite("SQL export file splitting")
struct SQLExportFileWriterTests {

    @Test("A part keeps the compound extension so the file still opens as SQL")
    func partKeepsCompoundExtension() {
        let base = URL(fileURLWithPath: "/tmp/dump.sql")
        #expect(SQLExportFileWriter.partURL(for: base, part: 2).lastPathComponent == "dump.part2.sql")

        let compressed = URL(fileURLWithPath: "/tmp/dump.sql.gz")
        #expect(SQLExportFileWriter.partURL(for: compressed, part: 3).lastPathComponent == "dump.part3.sql.gz")
    }

    @Test("A name with no extension still numbers its parts")
    func partWithoutExtension() {
        let base = URL(fileURLWithPath: "/tmp/dump")
        #expect(SQLExportFileWriter.partURL(for: base, part: 1).lastPathComponent == "dump.part1")
    }

    @Test("A name with a dot in its stem splits at the first dot")
    func partWithDottedStem() {
        let base = URL(fileURLWithPath: "/tmp/app.v2.sql")
        #expect(SQLExportFileWriter.partURL(for: base, part: 2).lastPathComponent == "app.part2.v2.sql")
    }

    @Test("An unsplit export keeps the name the user chose")
    func unsplitKeepsChosenName() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("dump.sql")
        let writer = try SQLExportFileWriter(destination: destination, splitSizeMegabytes: 0)
        try writer.write("SELECT 1;\n")
        let written = try writer.commit()

        #expect(written == [destination])
        #expect(!writer.didSplit)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "SELECT 1;\n")
    }

    /// Rotation happens between writes, so a part always ends on a whole statement.
    @Test("Passing the cap starts a new part without splitting a statement")
    func splittingKeepsStatementsWhole() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("dump.sql")
        let writer = try SQLExportFileWriter(destination: destination, splitSizeMegabytes: 1)
        let chunk = String(repeating: "x", count: 700 * 1_024)
        try writer.write("A\(chunk);\n")
        try writer.write("B\(chunk);\n")
        let written = try writer.commit()

        #expect(writer.didSplit)
        #expect(written.count == 2)
        #expect(written[0].lastPathComponent == "dump.part1.sql")
        #expect(written[1].lastPathComponent == "dump.part2.sql")

        let firstPart = try String(contentsOf: written[0], encoding: .utf8)
        let secondPart = try String(contentsOf: written[1], encoding: .utf8)
        #expect(firstPart.hasPrefix("A"))
        #expect(firstPart.hasSuffix(";\n"))
        #expect(secondPart.hasPrefix("B"))
        #expect(secondPart.hasSuffix(";\n"))
    }

    @Test("A rolled back export leaves nothing behind")
    func rollbackLeavesNothing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("dump.sql")
        let writer = try SQLExportFileWriter(destination: destination, splitSizeMegabytes: 1)
        try writer.write(String(repeating: "y", count: 2 * 1_024 * 1_024))
        try writer.write("tail;\n")
        writer.rollback()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining.isEmpty, "left behind: \(remaining)")
    }
}

@Suite("SQL export snapshot")
struct SQLExportSnapshotTests {

    @Test("Each dialect opens its own consistent-read transaction")
    func dialectSpecificBegin() {
        #expect(SQLExportSnapshot(dialect: .mysql).beginStatement == "START TRANSACTION WITH CONSISTENT SNAPSHOT")
        #expect(SQLExportSnapshot(dialect: .postgres).beginStatement == "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        #expect(SQLExportSnapshot(dialect: .sqlite).beginStatement == "BEGIN")
    }

    /// An engine with no spelling for this opens nothing rather than sending a statement it would
    /// reject and failing the whole export.
    @Test("An engine with no snapshot statement opens and closes nothing")
    func genericDialectOpensNothing() {
        let snapshot = SQLExportSnapshot(dialect: .generic)
        #expect(snapshot.beginStatement == nil)
        #expect(snapshot.endStatement == nil)
    }

    @Test("Every dialect that opens a transaction also closes it")
    func openingImpliesClosing() {
        for dialect in SqlDialect.allCases {
            let snapshot = SQLExportSnapshot(dialect: dialect)
            #expect((snapshot.beginStatement == nil) == (snapshot.endStatement == nil))
        }
    }
}
