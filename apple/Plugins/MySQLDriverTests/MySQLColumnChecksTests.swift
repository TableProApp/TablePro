//
//  MySQLColumnChecksTests.swift
//  TableProTests
//
//  MariaDB drops a column's own CHECK on any MODIFY that does not restate it, the json_valid check
//  on a JSON column included.
//

import Foundation
import TableProMySQLCore
import TableProPluginKit
import Testing

struct MySQLColumnChecksTests {
    /// MariaDB 11.4's own statement after `CHANGE COLUMN n m ...`: the constraint is still named `n` in the
    /// catalog, while the clause and the line say `m`.
    private let createTable = """
        CREATE TABLE `implA_c` (
          `id` int(11) NOT NULL,
          `j` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`j`)),
          `m` int(11) DEFAULT NULL CHECK (`m` > 0),
          `a` int(11) DEFAULT NULL,
          `b` int(11) DEFAULT NULL CHECK (`b` > `a`),
          `g` int(11) GENERATED ALWAYS AS (`a` + 1) VIRTUAL CHECK (`g` > 0),
          PRIMARY KEY (`id`),
          CONSTRAINT `tbl` CHECK (`a` < 100)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci
        """

    private func column(_ name: String, _ dataType: String = "INT", check: String? = nil) -> PluginColumnDefinition {
        PluginColumnDefinition(
            name: name,
            dataType: dataType,
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: nil,
            ddlDefault: nil,
            ddlGenerationExpression: nil,
            ddlCollation: nil,
            columnCheck: check
        )
    }

    // MARK: - Placement

    @Test("Each clause goes to the column whose line ends with it, whatever the constraint is named")
    func clausesArePlacedByLine() {
        let placed = MySQLColumnChecks.place(
            clauses: ["`b` > `a`", "`g` > 0", "json_valid(`j`)", "`m` > 0"],
            columns: ["id", "j", "m", "a", "b", "g"],
            createTable: createTable
        )
        #expect(placed == ["j": "json_valid(`j`)", "m": "`m` > 0", "b": "`b` > `a`", "g": "`g` > 0"])
    }

    @Test("Under ANSI_QUOTES the names and the clauses are double-quoted")
    func ansiQuotesArePlaced() {
        let ansi = createTable.replacingOccurrences(of: "`", with: "\"")
        let placed = MySQLColumnChecks.place(
            clauses: ["\"m\" > 0", "json_valid(\"j\")"],
            columns: ["id", "j", "m"],
            createTable: ansi
        )
        #expect(placed == ["j": "json_valid(\"j\")", "m": "\"m\" > 0"])
    }

    @Test("A clause no column line ends with is placed nowhere")
    func unplacedClauseStaysUnplaced() {
        let placed = MySQLColumnChecks.place(clauses: ["`zz` > 0"], columns: ["id", "m"], createTable: createTable)
        #expect(placed.isEmpty)
    }

    @Test("A table-level constraint is never a column's")
    func tableLevelCheckIsNotPlaced() {
        let placed = MySQLColumnChecks.place(clauses: ["`a` < 100"], columns: ["a"], createTable: createTable)
        #expect(placed.isEmpty)
    }

    @Test("The read asks for column-level checks only")
    func clausesQueryFiltersLevel() {
        let sql = MySQLColumnChecks.clausesQuery(schema: "shop", table: "orders")
        #expect(sql.contains("CONSTRAINT_SCHEMA = 'shop'"))
        #expect(sql.contains("TABLE_NAME = 'orders'"))
        #expect(sql.contains("LEVEL = 'Column'"))
    }

    // MARK: - Restatement

    @Test("A rename rewrites the column's own name in both quote styles")
    func renameRewritesOwnName() {
        #expect(MySQLColumnChecks.restated("`n` > 0 AND `n` < 10", renaming: "n", to: "m") == "`m` > 0 AND `m` < 10")
        #expect(MySQLColumnChecks.restated("\"n\" > 0", renaming: "n", to: "m") == "\"m\" > 0")
        #expect(MySQLColumnChecks.restated("`nn` > `n`", renaming: "n", to: "m") == "`nn` > `m`")
    }

    @Test("A rename leaves string literals as written, a JSON path that spells the name included")
    func renameKeepsStringLiterals() {
        #expect(MySQLColumnChecks.restated(#"json_extract(`n`, '$."n"') IS NOT NULL"#, renaming: "n", to: "payload")
            == #"json_extract(`payload`, '$."n"') IS NOT NULL"#)
        #expect(MySQLColumnChecks.restated("`n` <> '`n`'", renaming: "n", to: "m") == "`m` <> '`n`'")
        #expect(MySQLColumnChecks.restated(#"`n` <> 'it''s `n`' AND `n` <> 'it\'s `n`'"#, renaming: "n", to: "m")
            == #"`m` <> 'it''s `n`' AND `m` <> 'it\'s `n`'"#)
        #expect(MySQLColumnChecks.restated(#""n" <> '"n"'"#, renaming: "n", to: "m") == #""m" <> '"n"'"#)
    }

    @Test("A rename rewrites whole identifiers only, never one holding the name or an escaped quote")
    func renameMatchesWholeIdentifiers() {
        #expect(MySQLColumnChecks.restated("`nn` > `n` AND `n_x` > 0", renaming: "n", to: "m") == "`nn` > `m` AND `n_x` > 0")
        #expect(MySQLColumnChecks.restated("`x``n` > `n`", renaming: "n", to: "m") == "`x``n` > `m`")
        #expect(MySQLColumnChecks.restated("`n``` > 0", renaming: "n", to: "m") == "`n``` > 0")
        #expect(MySQLColumnChecks.restated(#""x""n" > "n""#, renaming: "n", to: "m") == #""x""n" > "m""#)
    }

    @Test("A rename matches the name without regard to case, and quotes a name holding a backtick")
    func renameIgnoresCaseAndEscapesTheNewName() {
        #expect(MySQLColumnChecks.restated("`N` > 0", renaming: "n", to: "m") == "`m` > 0")
        #expect(MySQLColumnChecks.restated("`a``b` > 0", renaming: "a`b", to: "c`d") == "`c``d` > 0")
    }

    @Test("Without a rename the clause is restated as read")
    func noRenameKeepsTheClause() {
        #expect(MySQLColumnChecks.restated("json_valid(`j`)", renaming: "j", to: "j") == "json_valid(`j`)")
        #expect(MySQLColumnChecks.restated(nil, renaming: "j", to: "k") == nil)
        #expect(MySQLColumnChecks.restated("", renaming: "j", to: "k") == nil)
    }

    @Test("The check is the last clause on the column, after the comment")
    func checkIsRestatedLast() {
        let definition = PluginColumnDefinition(name: "n", dataType: "INT", comment: "positive")
        #expect(mysqlColumnDefinitionSQL(definition, isMariaDB: true, columnCheck: "`n` > 0")
            == "`n` INT NULL COMMENT 'positive' CHECK (`n` > 0)")
    }

    @Test("A JSON column's json_valid check is restated with its charset")
    func jsonValidIsRestated() {
        let definition = PluginColumnDefinition(
            name: "j", dataType: "LONGTEXT", charset: "utf8mb4", collation: "utf8mb4_bin"
        )
        #expect(mysqlColumnDefinitionSQL(definition, isMariaDB: true, columnCheck: "json_valid(`j`)")
            == "`j` LONGTEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NULL CHECK (json_valid(`j`))")
    }

    @Test("A generated column restates its check after the storage keyword")
    func generatedColumnCheck() {
        let definition = PluginColumnDefinition(
            name: "g", dataType: "INT", generationExpression: "`a` + 1", generationKind: .virtual
        )
        #expect(mysqlColumnDefinitionSQL(definition, isMariaDB: true, columnCheck: "`g` > 0")
            == "`g` INT GENERATED ALWAYS AS (`a` + 1) VIRTUAL CHECK (`g` > 0)")
    }

    @Test("A MySQL driver never restates a column check, which MySQL keeps as a table constraint")
    func mysqlDoesNotRestate() throws {
        let driver = MySQLPluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: ""
        ))
        let sql = try #require(driver.generateModifyColumnSQL(
            table: "t", oldColumn: column("n", check: "`n` > 0"), newColumn: column("n", "BIGINT", check: "`n` > 0")
        ))
        #expect(!sql.contains("CHECK"))
    }

    // MARK: - Refusal

    @Test("A restated check naming another column this save renames is refused")
    func checkNamingRenamedColumnIsRefused() throws {
        let refusal = try #require(MySQLColumnChecks.renameRefusal(operations: [
            .modifyColumn(old: column("a"), new: column("a2")),
            .modifyColumn(old: column("b", check: "`b` > `a`"), new: column("b", "BIGINT", check: "`b` > `a`"))
        ]))
        #expect(refusal.contains("column b names column a"))
    }

    @Test("Under ANSI_QUOTES the renamed name is found in double quotes too")
    func ansiQuotedNameIsRefused() {
        #expect(MySQLColumnChecks.renameRefusal(operations: [
            .modifyColumn(old: column("b", check: "\"b\" > \"a\""), new: column("b", "BIGINT", check: "\"b\" > \"a\"")),
            .modifyColumn(old: column("a"), new: column("a2"))
        ]) != nil)
    }

    @Test("A column renamed with its own check is restated under the new name, not refused")
    func ownRenameIsAllowed() {
        #expect(MySQLColumnChecks.renameRefusal(operations: [
            .modifyColumn(old: column("n", check: "`n` > 0"), new: column("m", check: "`n` > 0"))
        ]) == nil)
    }

    @Test("A rename next to a check that does not name it is allowed")
    func unrelatedRenameIsAllowed() {
        #expect(MySQLColumnChecks.renameRefusal(operations: [
            .modifyColumn(old: column("c"), new: column("c2")),
            .modifyColumn(old: column("b", check: "`b` > `a`"), new: column("b", "BIGINT", check: "`b` > `a`")),
            .addColumn(column("z"))
        ]) == nil)
    }

    @Test("A string literal spelling a renamed column's name does not name the column")
    func literalSpellingARenamedColumnIsAllowed() {
        #expect(MySQLColumnChecks.renameRefusal(operations: [
            .modifyColumn(old: column("a"), new: column("a2")),
            .modifyColumn(old: column("b", check: "`b` <> '`a`'"), new: column("b", "BIGINT", check: "`b` <> '`a`'"))
        ]) == nil)
    }

    @Test("A column with no check of its own is never refused")
    func columnWithoutCheckIsAllowed() {
        #expect(MySQLColumnChecks.renameRefusal(operations: [
            .modifyColumn(old: column("a"), new: column("a2")),
            .modifyColumn(old: column("b"), new: column("b", "BIGINT"))
        ]) == nil)
    }
}
