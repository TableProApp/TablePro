//
//  SQLiteTableRespecifierTests.swift
//  TablePro
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("SQLite Table Respecifier")
struct SQLiteTableRespecifierTests {
    private let createSQL = """
        CREATE TABLE x(
          a INTEGER PRIMARY KEY,
          b TEXT NOT NULL DEFAULT 'hi, there' COLLATE NOCASE,
          c DECIMAL(10,2) CHECK (c > 0),
          pid INTEGER REFERENCES parent(id) ON DELETE CASCADE,
          CHECK (length(b) < 100),
          UNIQUE(a, b)
        )
        """

    private func respecify(
        _ respecification: PluginTableRespecification,
        sql: String? = nil
    ) throws -> SQLiteRespecifiedTable {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: sql ?? createSQL))
        return try #require(
            SQLiteTableDDL.respecified(
                parsed,
                tableName: "x_new",
                respecification: respecification,
                renderColumn: { "\"\($0.name)\" \($0.dataType)" }
            )
        )
    }

    private func foreignKey(
        _ name: String,
        _ columns: [String],
        _ table: String,
        _ referenced: [String]
    ) -> PluginForeignKeyDefinition {
        PluginForeignKeyDefinition(
            name: name, columns: columns, referencedTable: table, referencedColumns: referenced
        )
    }

    // MARK: - Preservation

    /// The whole reason a rebuild rewrites stored text rather than re-rendering from a model: none
    /// of these survive a trip through `PRAGMA table_info`.
    @Test("Every untouched column keeps its own text")
    func preservesUntouchedColumnText() throws {
        let sql = try respecify(
            PluginTableRespecification(addedForeignKeys: [foreignKey("fk", ["c"], "p", ["id"])])
        ).createTableSQL

        #expect(sql.contains("b TEXT NOT NULL DEFAULT 'hi, there' COLLATE NOCASE"))
        #expect(sql.contains("c DECIMAL(10,2) CHECK (c > 0)"))
        #expect(sql.contains("CHECK (length(b) < 100)"))
        #expect(sql.contains("UNIQUE(a, b)"))
    }

    @Test("A WITHOUT ROWID table keeps its trailing options")
    func preservesTrailingOptions() throws {
        let sql = try respecify(
            PluginTableRespecification(addedForeignKeys: [foreignKey("fk", ["k"], "p", ["id"])]),
            sql: "CREATE TABLE x(k TEXT PRIMARY KEY, v INT) WITHOUT ROWID"
        ).createTableSQL
        #expect(sql.hasSuffix("WITHOUT ROWID"))
    }

    // MARK: - Foreign keys

    @Test("An added key becomes a table constraint at the end")
    func addsATableLevelKey() throws {
        let sql = try respecify(
            PluginTableRespecification(addedForeignKeys: [foreignKey("fk_x_c", ["c"], "other", ["id"])])
        ).createTableSQL
        #expect(sql.contains("CONSTRAINT \"fk_x_c\" FOREIGN KEY (\"c\") REFERENCES \"other\" (\"id\")"))
    }

    /// The clause lives inside the column definition, so dropping it means cutting exactly that
    /// span out and leaving the rest of the column as the user wrote it.
    @Test("Dropping a column-level key leaves the rest of the column alone")
    func dropsAColumnLevelKey() throws {
        let sql = try respecify(
            PluginTableRespecification(droppedForeignKeys: [foreignKey("", ["pid"], "parent", ["id"])])
        ).createTableSQL
        #expect(!sql.contains("REFERENCES"))
        #expect(!sql.contains("ON DELETE CASCADE"))
        #expect(sql.contains("pid INTEGER"))
    }

    @Test("Dropping a table-level key removes its whole entry")
    func dropsATableLevelKey() throws {
        let sql = try respecify(
            PluginTableRespecification(droppedForeignKeys: [foreignKey("", ["b"], "p", ["id"])]),
            sql: """
                CREATE TABLE x(a INT, b INT, CONSTRAINT keep CHECK (a > 0),
                  CONSTRAINT gone FOREIGN KEY (b) REFERENCES p (id))
                """
        ).createTableSQL
        #expect(!sql.contains("gone"))
        #expect(sql.contains("CONSTRAINT keep CHECK (a > 0)"))
    }

    /// Rebuilding without a key the save asked to drop would report success over a key that is
    /// still there.
    @Test("A key that is not in the statement fails the respecification")
    func refusesToDropAKeyThatIsNotThere() throws {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: createSQL))
        #expect(
            SQLiteTableDDL.respecified(
                parsed,
                tableName: "x_new",
                respecification: PluginTableRespecification(
                    droppedForeignKeys: [foreignKey("", ["pid"], "elsewhere", ["id"])]
                ),
                renderColumn: { _ in "" }
            ) == nil
        )
    }

    @Test("Replacing a key drops the old clause and writes the new one")
    func replacesAKey() throws {
        let sql = try respecify(
            PluginTableRespecification(
                addedForeignKeys: [
                    PluginForeignKeyDefinition(
                        name: "fk_new", columns: ["pid"], referencedTable: "parent",
                        referencedColumns: ["id"], onDelete: "SET NULL"
                    )
                ],
                droppedForeignKeys: [foreignKey("", ["pid"], "parent", ["id"])]
            )
        ).createTableSQL
        #expect(sql.contains("CONSTRAINT \"fk_new\""))
        #expect(sql.contains("ON DELETE SET NULL"))
        #expect(!sql.contains("ON DELETE CASCADE"))
    }

    // MARK: - Columns

    @Test("An added column is rendered after the existing ones and carries no data")
    func addsAColumn() throws {
        let respecified = try respecify(
            PluginTableRespecification(
                addedColumns: [
                    PluginColumnDefinition(name: "email", dataType: "TEXT", isNullable: true)
                ],
                addedForeignKeys: [foreignKey("fk", ["email"], "users", ["email"])]
            )
        )
        #expect(respecified.createTableSQL.contains("\"email\" TEXT"))
        #expect(!respecified.carriedColumns.contains { $0.name == "email" })
    }

    @Test("A dropped column goes, and so does the data it would have carried")
    func dropsAColumn() throws {
        let respecified = try respecify(
            PluginTableRespecification(
                droppedColumns: ["c"],
                addedForeignKeys: [foreignKey("fk", ["a"], "p", ["id"])]
            )
        )
        #expect(!respecified.createTableSQL.contains("DECIMAL(10,2)"))
        #expect(!respecified.carriedColumns.contains { $0.name == "c" })
    }

    /// A key on a column that is going away cannot survive the rebuild, and leaving it in makes the
    /// `CREATE TABLE` invalid rather than making the drop fail.
    @Test("Dropping a column takes its foreign key with it")
    func dropsAKeyWithItsColumn() throws {
        let sql = try respecify(
            PluginTableRespecification(
                droppedColumns: ["pid"],
                addedForeignKeys: [foreignKey("fk", ["a"], "p", ["id"])]
            )
        ).createTableSQL
        #expect(!sql.contains("parent"))
    }

    @Test("A renamed column keeps its definition and is copied from its old name")
    func renamesAColumn() throws {
        let respecified = try respecify(
            PluginTableRespecification(
                renamedColumns: ["b": "label"],
                addedForeignKeys: [foreignKey("fk", ["a"], "p", ["id"])]
            )
        )
        #expect(respecified.createTableSQL.contains("\"label\" TEXT NOT NULL DEFAULT 'hi, there' COLLATE NOCASE"))
        let carried = try #require(respecified.carriedColumns.first { $0.name == "label" })
        #expect(carried.sourceName == "b")
    }

    /// A table constraint naming the renamed column would otherwise name a column that no longer
    /// exists, and SQLite would refuse the `CREATE TABLE`.
    @Test("A renamed column is carried into a table-level foreign key on it")
    func carriesARenameIntoATableLevelKey() throws {
        let sql = try respecify(
            PluginTableRespecification(
                renamedColumns: ["b": "label"],
                addedForeignKeys: [foreignKey("added", ["a"], "p", ["id"])]
            ),
            sql: "CREATE TABLE x(a INT, b INT, CONSTRAINT fk FOREIGN KEY (b) REFERENCES p (id))"
        ).createTableSQL
        #expect(sql.contains("FOREIGN KEY (\"label\") REFERENCES \"p\" (\"id\")"))
    }

    @Test("A rename of a column the statement does not define fails the respecification")
    func refusesAnUnknownRename() throws {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: createSQL))
        #expect(
            SQLiteTableDDL.respecified(
                parsed,
                tableName: "x_new",
                respecification: PluginTableRespecification(renamedColumns: ["nope": "other"]),
                renderColumn: { _ in "" }
            ) == nil
        )
    }

    // MARK: - Order

    @Test("A wanted order rearranges the columns and the copy list together")
    func appliesAColumnOrder() throws {
        let respecified = try respecify(PluginTableRespecification(columnOrder: ["pid", "a", "b", "c"]))
        #expect(respecified.carriedColumns.map(\.name) == ["pid", "a", "b", "c"])
        let body = respecified.createTableSQL
        let pidIndex = try #require(body.range(of: "pid INTEGER"))
        let aIndex = try #require(body.range(of: "a INTEGER PRIMARY KEY"))
        #expect(pidIndex.lowerBound < aIndex.lowerBound)
    }

    @Test("An order that is not a permutation of the resulting columns is refused")
    func refusesANonPermutation() throws {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: createSQL))
        #expect(
            SQLiteTableDDL.respecified(
                parsed,
                tableName: "x_new",
                respecification: PluginTableRespecification(columnOrder: ["a", "b"]),
                renderColumn: { _ in "" }
            ) == nil
        )
    }

    // MARK: - Rowid tables

    @Test("WITHOUT ROWID is recognised, and an ordinary table is not mistaken for one")
    func recognisesWithoutRowid() throws {
        let ordinary = try #require(SQLiteTableDDL.parse(createTableSQL: createSQL))
        #expect(SQLiteTableDDL.isRowidTable(ordinary))

        let without = try #require(
            SQLiteTableDDL.parse(createTableSQL: "CREATE TABLE x(k TEXT PRIMARY KEY) WITHOUT ROWID")
        )
        #expect(!SQLiteTableDDL.isRowidTable(without))
    }
}
