//
//  CrossEngineCollationSpellingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct CrossEngineCollationSpellingTests {
    private func snapshot(ddlCollation: String?) -> TableStructureSnapshot {
        let code = EditableColumnDefinition(
            id: UUID(),
            name: "code",
            dataType: "TEXT",
            isNullable: true,
            defaultValue: nil,
            autoIncrement: false,
            unsigned: false,
            comment: nil,
            collation: "C",
            onUpdate: nil,
            charset: nil,
            extra: nil,
            isPrimaryKey: false,
            ddlSpelling: "text",
            ddlCollation: ddlCollation
        )
        return TableStructureSnapshot(name: "orders", schema: "sales", columns: [code])
    }

    @Test("A PostgreSQL collation spelling does not cross into MySQL")
    func translationDropsCollationSpelling() {
        let result = CrossEngineStructureTranslator.translate(
            snapshot(ddlCollation: #"pg_catalog."C""#), from: .postgresql, to: .mysql
        )
        #expect(result.translated)
        #expect(result.snapshot.columns.map(\.collation) == [nil])
        #expect(result.snapshot.columns.map(\.ddlCollation) == [nil])
    }

    @Test("A copy within PostgreSQL keeps the collation spelling")
    func sameFamilyKeepsCollationSpelling() {
        let result = CrossEngineStructureTranslator.translate(
            snapshot(ddlCollation: #"app."Case Insens""#), from: .postgresql, to: .postgresql
        )
        #expect(!result.translated)
        #expect(result.snapshot.columns.map(\.ddlCollation) == [#"app."Case Insens""#])
    }
}
