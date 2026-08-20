//
//  StructureEditingSupportBooleanParsingTests.swift
//  TableProTests
//
//  The structure grid displays boolean flags as YES/NO, but the dropdown that
//  edits them has offered true/false on dialects whose boolean literal style is
//  truefalse. The parser only accepted YES or 1, so picking true wrote false.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("StructureEditingSupport Boolean Parsing")
@MainActor
struct StructureEditingSupportBooleanParsingTests {
    private static let postgresOrderedFields: [StructureColumnField] = [
        .name, .type, .nullable, .defaultValue, .primaryKey, .autoIncrement, .comment
    ]

    private static let mysqlOrderedFields: [StructureColumnField] = [
        .name, .type, .nullable, .defaultValue, .onUpdate, .primaryKey, .autoIncrement, .comment
    ]

    nonisolated private static let trueTokens = ["YES", "yes", "Yes", "TRUE", "true", "True", "1"]
    nonisolated private static let falseTokens = ["NO", "no", "FALSE", "false", "0", "", "maybe"]

    private func makeColumn() -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(),
            name: "id",
            dataType: "INT",
            isNullable: false,
            defaultValue: nil,
            autoIncrement: false,
            unsigned: false,
            comment: nil,
            collation: nil,
            onUpdate: nil,
            charset: nil,
            extra: nil,
            isPrimaryKey: false
        )
    }

    private func index(of field: StructureColumnField) -> Int {
        guard let index = Self.postgresOrderedFields.firstIndex(of: field) else {
            Issue.record("Field \(field) missing from fixture")
            return -1
        }
        return index
    }

    // MARK: - parseBool

    @Test("Every dropdown vocabulary spells true", arguments: trueTokens)
    func parsesTrueTokens(token: String) {
        #expect(StructureEditingSupport.parseBool(token))
    }

    @Test("Anything else is false", arguments: falseTokens)
    func parsesFalseTokens(token: String) {
        #expect(StructureEditingSupport.parseBool(token) == false)
    }

    // MARK: - Primary Key

    @Test("Primary Key accepts true, the token truefalse dialects send", arguments: trueTokens)
    func primaryKeyAcceptsEveryTrueToken(token: String) {
        var column = makeColumn()
        StructureEditingSupport.updateColumn(
            &column,
            at: index(of: .primaryKey),
            with: token,
            orderedFields: Self.postgresOrderedFields
        )
        #expect(column.isPrimaryKey)
    }

    @Test("Primary Key clears on a false token")
    func primaryKeyClears() {
        var column = makeColumn()
        column.isPrimaryKey = true
        StructureEditingSupport.updateColumn(
            &column,
            at: index(of: .primaryKey),
            with: "NO",
            orderedFields: Self.postgresOrderedFields
        )
        #expect(column.isPrimaryKey == false)
    }

    // MARK: - Nullable and Auto Inc

    @Test("Nullable accepts every true token", arguments: trueTokens)
    func nullableAcceptsEveryTrueToken(token: String) {
        var column = makeColumn()
        StructureEditingSupport.updateColumn(
            &column,
            at: index(of: .nullable),
            with: token,
            orderedFields: Self.postgresOrderedFields
        )
        #expect(column.isNullable)
    }

    @Test("Auto Inc accepts every true token", arguments: trueTokens)
    func autoIncrementAcceptsEveryTrueToken(token: String) {
        var column = makeColumn()
        StructureEditingSupport.updateColumn(
            &column,
            at: index(of: .autoIncrement),
            with: token,
            orderedFields: Self.postgresOrderedFields
        )
        #expect(column.autoIncrement)
    }

    // MARK: - On Update

    @Test("On Update accepts every true token", arguments: trueTokens)
    func onUpdateAcceptsEveryTrueToken(token: String) {
        var column = makeColumn()
        StructureEditingSupport.updateColumn(
            &column,
            at: Self.mysqlOrderedFields.firstIndex(of: .onUpdate) ?? -1,
            with: token,
            orderedFields: Self.mysqlOrderedFields
        )
        #expect(column.onUpdate == "CURRENT_TIMESTAMP")
    }

    @Test("On Update clears on a false token", arguments: falseTokens)
    func onUpdateClears(token: String) {
        var column = makeColumn()
        column.onUpdate = "CURRENT_TIMESTAMP"
        StructureEditingSupport.updateColumn(
            &column,
            at: Self.mysqlOrderedFields.firstIndex(of: .onUpdate) ?? -1,
            with: token,
            orderedFields: Self.mysqlOrderedFields
        )
        #expect(column.onUpdate == nil)
    }

    // MARK: - Primary key implies NOT NULL

    @Test("Marking a column as the primary key clears Nullable")
    func primaryKeyClearsNullable() {
        var column = makeColumn()
        column.isNullable = true
        StructureEditingSupport.updateColumn(
            &column,
            at: index(of: .primaryKey),
            with: "YES",
            orderedFields: Self.postgresOrderedFields
        )
        #expect(column.isPrimaryKey)
        #expect(column.isNullable == false)
    }

    @Test("A primary key column refuses to become nullable")
    func primaryKeyColumnStaysNotNull() {
        var column = makeColumn()
        column.isPrimaryKey = true
        StructureEditingSupport.updateColumn(
            &column,
            at: index(of: .nullable),
            with: "YES",
            orderedFields: Self.postgresOrderedFields
        )
        #expect(column.isNullable == false)
    }

    @Test("Clearing the primary key lets the column become nullable again")
    func clearingPrimaryKeyRestoresNullableEditing() {
        var column = makeColumn()
        column.isPrimaryKey = true
        StructureEditingSupport.updateColumn(
            &column,
            at: index(of: .primaryKey),
            with: "NO",
            orderedFields: Self.postgresOrderedFields
        )
        StructureEditingSupport.updateColumn(
            &column,
            at: index(of: .nullable),
            with: "YES",
            orderedFields: Self.postgresOrderedFields
        )
        #expect(column.isNullable)
    }

    // MARK: - Index Unique

    @Test("Index Unique accepts every true token", arguments: trueTokens)
    func indexUniqueAcceptsEveryTrueToken(token: String) {
        var definition = EditableIndexDefinition.placeholder()
        definition.name = "idx"
        definition.columns = ["id"]
        StructureEditingSupport.updateIndex(&definition, at: 3, with: token)
        #expect(definition.isUnique)
    }
}
