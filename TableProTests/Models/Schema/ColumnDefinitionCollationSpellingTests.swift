//
//  ColumnDefinitionCollationSpellingTests.swift
//  TableProTests
//
//  The server's COLLATE spelling on an editable column, from the catalog read to the DDL writer.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("EditableColumnDefinition collation spelling")
struct ColumnDefinitionCollationSpellingTests {
    private func column(
        collation: String? = "C",
        ddlCollation: String? = #"pg_catalog."C""#,
        charset: String? = nil
    ) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(),
            name: "code",
            dataType: "CHARACTER VARYING",
            isNullable: true,
            defaultValue: nil,
            autoIncrement: false,
            unsigned: false,
            comment: nil,
            collation: collation,
            onUpdate: nil,
            charset: charset,
            extra: nil,
            isPrimaryKey: false,
            ddlSpelling: "character varying(10)",
            ddlCollation: ddlCollation
        )
    }

    @Test("A type edit keeps the collation spelling and sets aside only the type's")
    func typeEditKeepsCollationSpelling() {
        var retyped = column()
        retyped.dataType = "VARCHAR(20)"
        #expect(retyped.ddlSpelling == nil)
        #expect(retyped.ddlCollation == #"pg_catalog."C""#)
    }

    @Test("A collation edit sets the spelling aside, and editing it back restores it")
    func collationEditRetiresSpelling() {
        let loaded = column()
        var edited = loaded
        edited.collation = "en_US"
        #expect(edited.ddlCollation == nil)
        edited.collation = "C"
        #expect(edited.ddlCollation == #"pg_catalog."C""#)
        #expect(edited == loaded)
    }

    @Test("A column with no collation name to show still carries the one it declares")
    func spellingPairsWithNilCollation() {
        var declared = column(collation: nil, ddlCollation: #"pg_catalog."default""#)
        #expect(declared.ddlCollation == #"pg_catalog."default""#)
        declared.collation = "C"
        #expect(declared.ddlCollation == nil)
    }

    @Test("A column said again in another engine's words carries no collation spelling")
    func droppingCatalogSpellingsClearsCollation() {
        var translated = column()
        translated.dropCatalogSpellings()
        #expect(translated.ddlCollation == nil)
        #expect(translated.collation == "C")
    }

    @Test("A column decoded from the clipboard carries no collation spelling")
    func decodingDropsCollationSpelling() throws {
        let data = try JSONEncoder().encode([column()])
        let decoded = try JSONDecoder().decode([EditableColumnDefinition].self, from: data)
        #expect(decoded.first?.collation == "C")
        #expect(decoded.first?.ddlCollation == nil)
    }

    @Test("The collation spelling travels from the column read to the DDL writer and back")
    func collationSpellingCarriesThroughConversions() {
        let columnInfo = ColumnInfo(
            name: "code",
            dataType: "TEXT",
            isNullable: true,
            isPrimaryKey: false,
            collation: "Case Insens",
            ddlSpelling: "text",
            ddlCollation: #"app."Case Insens""#
        )
        let editable = EditableColumnDefinition.from(columnInfo)
        #expect(editable.ddlCollation == #"app."Case Insens""#)
        #expect(editable.toPlugin().ddlCollation == #"app."Case Insens""#)
        #expect(editable.toColumnInfo().ddlCollation == #"app."Case Insens""#)
        #expect(editable.withNewIdentity().ddlCollation == #"app."Case Insens""#)
    }

    @Test("Keeping another column's collation takes its character set, collation and spelling together")
    func keepingCollationTakesAllThree() {
        let source = column(collation: "Case Insens", ddlCollation: #"app."Case Insens""#, charset: "UTF8")
        let target = column(collation: "C", ddlCollation: #"pg_catalog."C""#, charset: nil)
        var kept = source.keepingCollation(of: target)
        #expect(kept.collation == "C")
        #expect(kept.charset == nil)
        #expect(kept.ddlCollation == #"pg_catalog."C""#)
        #expect(kept.name == source.name)
        #expect(kept.id == source.id)
        kept.collation = "Case Insens"
        #expect(kept.ddlCollation == nil)
    }
}
