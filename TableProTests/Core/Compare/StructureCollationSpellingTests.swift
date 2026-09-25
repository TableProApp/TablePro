//
//  StructureCollationSpellingTests.swift
//  TableProTests
//
//  The server's COLLATE spelling through the structure snapshot and the structure comparison.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct StructureCollationSpellingTests {
    private func column(
        _ name: String,
        dataType: String = "text",
        ddlSpelling: String? = "text",
        nullable: Bool = true,
        collation: String?,
        ddlCollation: String?,
        charset: String? = nil
    ) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(),
            name: name,
            dataType: dataType,
            isNullable: nullable,
            defaultValue: nil,
            autoIncrement: false,
            unsigned: false,
            comment: nil,
            collation: collation,
            onUpdate: nil,
            charset: charset,
            extra: nil,
            isPrimaryKey: false,
            ddlSpelling: ddlSpelling,
            ddlCollation: ddlCollation
        )
    }

    private func comparingCollation() -> StructureCompareOptions {
        var options = StructureCompareOptions()
        options.ignoreCollationAndCharset = false
        return options
    }

    private func table(_ columns: [EditableColumnDefinition]) -> TableStructureSnapshot {
        TableStructureSnapshot(name: "orders", schema: "sales", columns: columns)
    }

    private func modifiedColumns(_ result: TableDiffResult) -> [(old: EditableColumnDefinition, new: EditableColumnDefinition)] {
        result.changes.compactMap { change in
            guard case .modifyColumn(let old, let new) = change else { return nil }
            return (old, new)
        }
    }

    @Test("A column read carries its collation spelling all the way to the CREATE TABLE definition")
    func snapshotCarriesCollationSpelling() {
        let code = PluginColumnInfo(
            name: "code",
            dataType: "TEXT",
            collation: "C",
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: "text",
            ddlDefault: nil,
            ddlGenerationExpression: nil,
            ddlCollation: #"pg_catalog."C""#,
            classificationTypeName: nil
        )
        let snapshot = TableStructureSnapshot.from(
            table: PluginTableInfo(name: "orders", schema: "sales", comment: nil),
            columns: [code],
            indexes: [],
            foreignKeys: []
        )
        #expect(snapshot.columns.first?.ddlCollation == #"pg_catalog."C""#)
        #expect(snapshot.columns.first?.toPlugin().ddlCollation == #"pg_catalog."C""#)
    }

    @Test("Ignoring collation, a column changed for another reason keeps the target's collation")
    func ignoredCollationKeepsTheTargets() throws {
        let source = table([column("code", nullable: false, collation: "Case Insens", ddlCollation: #"app."Case Insens""#)])
        let target = table([column("code", nullable: true, collation: "C", ddlCollation: #"pg_catalog."C""#, charset: "UTF8")])

        let modified = modifiedColumns(StructureDiffEngine().compareTable(source: source, target: target))
        let change = try #require(modified.first)
        #expect(modified.count == 1)
        #expect(!change.new.isNullable)
        #expect(change.new.collation == "C")
        #expect(change.new.charset == "UTF8")
        #expect(change.new.ddlCollation == #"pg_catalog."C""#)
        #expect(change.new.ddlCollation == change.old.ddlCollation)
    }

    @Test("Ignoring collation, a difference in collation alone is no change at all")
    func ignoredCollationAloneIsIdentical() {
        let source = table([column("code", collation: "Case Insens", ddlCollation: #"app."Case Insens""#)])
        let target = table([column("code", collation: "C", ddlCollation: #"pg_catalog."C""#)])
        #expect(StructureDiffEngine().compareTable(source: source, target: target).status == .identical)
    }

    @Test("Comparing collation, the change carries the source's collation and its spelling")
    func comparedCollationTakesTheSources() throws {
        let source = table([column("code", collation: "Case Insens", ddlCollation: #"app."Case Insens""#)])
        let target = table([column("code", collation: "C", ddlCollation: #"pg_catalog."C""#)])
        let modified = modifiedColumns(
            StructureDiffEngine(options: comparingCollation()).compareTable(source: source, target: target)
        )
        let change = try #require(modified.first)
        #expect(change.new.collation == "Case Insens")
        #expect(change.new.ddlCollation == #"app."Case Insens""#)
        #expect(change.old.ddlCollation == #"pg_catalog."C""#)
    }

    @Test("Ignoring collation, a MySQL string column retyped to INT takes none of the target's character set")
    func ignoredCollationRetypeToIntegerTakesNoCharset() throws {
        let source = table([column("code", dataType: "INT", ddlSpelling: nil, collation: nil, ddlCollation: nil)])
        let target = table([column(
            "code", dataType: "VARCHAR(50)", ddlSpelling: nil,
            collation: "utf8mb4_0900_ai_ci", ddlCollation: nil, charset: "utf8mb4"
        )])

        let change = try #require(modifiedColumns(StructureDiffEngine().compareTable(source: source, target: target)).first)
        #expect(change.new.charset == nil)
        #expect(change.new.collation == nil)
        #expect(mysqlColumnDefinitionSQL(change.new.toPlugin()) == "`code` INT NULL")
    }

    @Test("Ignoring collation, a PostgreSQL text column retyped to integer writes no COLLATE")
    func ignoredCollationRetypeToIntegerWritesNoCollate() throws {
        let source = table([column("code", dataType: "INTEGER", ddlSpelling: "integer", collation: nil, ddlCollation: nil)])
        let target = table([column("code", dataType: "TEXT", collation: "C", ddlCollation: #"pg_catalog."C""#)])

        let change = try #require(modifiedColumns(StructureDiffEngine().compareTable(source: source, target: target)).first)
        #expect(change.new.ddlCollation == nil)
        #expect(PostgreSQLColumnClauses.alterType(old: change.old.toPlugin(), new: change.new.toPlugin()) == "integer")
    }

    @Test("Ignoring collation, a retyped column keeps the collation read on its own type")
    func ignoredCollationRetypeKeepsTheSourcesOwn() throws {
        let source = table([column("code", collation: "C", ddlCollation: #"pg_catalog."C""#)])
        let target = table([column(
            "code", dataType: "CHARACTER VARYING", ddlSpelling: "app.c_varchar", collation: "C", ddlCollation: nil
        )])

        let change = try #require(modifiedColumns(StructureDiffEngine().compareTable(source: source, target: target)).first)
        #expect(change.new.ddlCollation == #"pg_catalog."C""#)
        #expect(
            PostgreSQLColumnClauses.alterType(old: change.old.toPlugin(), new: change.new.toPlugin())
                == #"text COLLATE pg_catalog."C""#
        )
    }

    @Test("Comparing collation, one name in two schemas is no collation change and writes no retype")
    func comparedCollationOfOneNameKeepsTheTargetsSpelling() throws {
        let source = table([column("email", nullable: false, collation: "Case Insens", ddlCollation: #"app."Case Insens""#)])
        let target = table([column("email", collation: "Case Insens", ddlCollation: #"tgt."Case Insens""#)])

        let result = StructureDiffEngine(options: comparingCollation()).compareTable(source: source, target: target)
        let change = try #require(modifiedColumns(result).first)
        #expect(!change.new.isNullable)
        #expect(change.new.ddlCollation == #"tgt."Case Insens""#)
        #expect(PostgreSQLColumnClauses.alterType(old: change.old.toPlugin(), new: change.new.toPlugin()) == nil)
    }

    @Test("Comparing collation, a retype with the same collation name carries the source's own spelling")
    func comparedCollationRetypeTakesTheSources() throws {
        let source = table([column("code", collation: "C", ddlCollation: #"pg_catalog."C""#)])
        let target = table([column(
            "code", dataType: "CHARACTER VARYING", ddlSpelling: "app.c_varchar", collation: "C", ddlCollation: nil
        )])

        let result = StructureDiffEngine(options: comparingCollation()).compareTable(source: source, target: target)
        let change = try #require(modifiedColumns(result).first)
        #expect(change.new.ddlCollation == #"pg_catalog."C""#)
    }
}
