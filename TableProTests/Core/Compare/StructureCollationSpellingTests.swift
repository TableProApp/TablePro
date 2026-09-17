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

@Suite("Structure collation spelling")
struct StructureCollationSpellingTests {
    private func column(
        _ name: String,
        nullable: Bool = true,
        collation: String?,
        ddlCollation: String?,
        charset: String? = nil
    ) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(),
            name: name,
            dataType: "text",
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
            ddlSpelling: "text",
            ddlCollation: ddlCollation
        )
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
            ddlCollation: #"pg_catalog."C""#
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
        var options = StructureCompareOptions()
        options.ignoreCollationAndCharset = false

        let modified = modifiedColumns(StructureDiffEngine(options: options).compareTable(source: source, target: target))
        let change = try #require(modified.first)
        #expect(change.new.collation == "Case Insens")
        #expect(change.new.ddlCollation == #"app."Case Insens""#)
        #expect(change.old.ddlCollation == #"pg_catalog."C""#)
    }
}
