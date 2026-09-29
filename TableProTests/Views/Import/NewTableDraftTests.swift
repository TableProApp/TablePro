//
//  NewTableDraftTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// Changing a parsing option reads the file again. Rebuilding the new table's columns from that read
/// threw away every rename, type, key, nullability, default and exclusion the user had set.
struct NewTableDraftTests {
    private static func sqlType(_ type: PluginImportFieldType) -> String {
        switch type {
        case .integer: return "INTEGER"
        case .real: return "REAL"
        default: return "TEXT"
        }
    }

    private func field(_ name: String, _ type: PluginImportFieldType = .text) -> PluginImportField {
        PluginImportField(name: name, sampleValue: nil, inferredType: type)
    }

    private func makeDraft(_ fields: [PluginImportField]) -> NewTableDraft {
        var draft = NewTableDraft()
        draft.load(fields: fields, proposingType: Self.sqlType)
        return draft
    }

    private func edit(
        _ name: String,
        in draft: inout NewTableDraft,
        _ change: (inout NewTableColumnSettings) -> Void
    ) throws {
        let index = try #require(draft.columns.firstIndex { $0.field.name == name })
        change(&draft.columns[index].settings)
    }

    private func settings(of name: String, in draft: NewTableDraft) throws -> NewTableColumnSettings {
        try #require(draft.columns.first { $0.field.name == name }).settings
    }

    @Test("The first read proposes every field under its own name, nullable, with no key and no default")
    func firstReadProposesEachField() throws {
        let draft = makeDraft([field("id", .integer), field("name")])

        #expect(try settings(of: "id", in: draft) == .proposed(name: "id", type: "INTEGER"))
        #expect(try settings(of: "name", in: draft) == NewTableColumnSettings(
            include: true, name: "name", type: "TEXT", isPrimaryKey: false, isNullable: true, defaultValue: ""
        ))
    }

    @Test("A re-read keeps every setting the user changed on a field that survives it")
    func reReadKeepsEdits() throws {
        var draft = makeDraft([field("id", .integer), field("name"), field("notes")])
        try edit("id", in: &draft) {
            $0.name = "person_id"
            $0.type = "BIGINT"
            $0.isPrimaryKey = true
            $0.isNullable = false
        }
        try edit("name", in: &draft) { $0.defaultValue = "'unknown'" }
        try edit("notes", in: &draft) { $0.include = false }

        draft.load(fields: [field("id", .integer), field("name"), field("notes")], proposingType: Self.sqlType)

        #expect(try settings(of: "id", in: draft) == NewTableColumnSettings(
            include: true, name: "person_id", type: "BIGINT", isPrimaryKey: true, isNullable: false, defaultValue: ""
        ))
        #expect(try settings(of: "name", in: draft).defaultValue == "'unknown'")
        #expect(try settings(of: "notes", in: draft).include == false)
    }

    /// Trimming spaces turns `" 42 "` into a number, so a type the user never touched has to follow
    /// the read rather than stay at what the untrimmed values suggested.
    @Test("A type the user left alone follows the type the new read infers")
    func untouchedTypeFollowsTheRead() throws {
        var draft = makeDraft([field("amount"), field("code")])
        try edit("code", in: &draft) { $0.isPrimaryKey = true }

        draft.load(fields: [field("amount", .integer), field("code", .integer)], proposingType: Self.sqlType)

        #expect(try settings(of: "amount", in: draft).type == "INTEGER")
        #expect(try settings(of: "code", in: draft).type == "INTEGER")
        #expect(try settings(of: "code", in: draft).isPrimaryKey)
    }

    @Test("A type the user chose stays when the new read infers another")
    func chosenTypeStays() throws {
        var draft = makeDraft([field("amount")])
        try edit("amount", in: &draft) { $0.type = "NUMERIC(10,2)" }

        draft.load(fields: [field("amount", .integer)], proposingType: Self.sqlType)

        #expect(try settings(of: "amount", in: draft).type == "NUMERIC(10,2)")
    }

    /// The type menu offers the dialect's own spelling of a proposal, so choosing it again can write
    /// back `integer` for a proposed `INTEGER` without the user changing anything.
    @Test("A type differing from the proposal only in case counts as left alone")
    func caseOnlyTypeChangeIsNotAnEdit() throws {
        var draft = makeDraft([field("amount", .integer)])
        try edit("amount", in: &draft) { $0.type = "integer" }

        draft.load(fields: [field("amount", .real)], proposingType: Self.sqlType)

        #expect(try settings(of: "amount", in: draft).type == "REAL")
    }

    @Test("A setting changed and then put back follows the read like one never changed")
    func revertedSettingFollowsTheRead() throws {
        var draft = makeDraft([field("amount")])
        try edit("amount", in: &draft) { $0.type = "BIGINT" }
        try edit("amount", in: &draft) { $0.type = "TEXT" }

        draft.load(fields: [field("amount", .integer)], proposingType: Self.sqlType)

        #expect(try settings(of: "amount", in: draft).type == "INTEGER")
    }

    /// The proposal a later read compares against is the one that read made, not the first one, so
    /// the user's edit is judged against what the sheet was showing when it was made.
    @Test("An edit survives several re-reads, and a later read's own proposals stay unedited")
    func editsSurviveSeveralReads() throws {
        var draft = makeDraft([field("amount"), field("code")])
        try edit("code", in: &draft) { $0.name = "sku" }

        draft.load(fields: [field("amount", .integer), field("code")], proposingType: Self.sqlType)
        draft.load(fields: [field("amount", .real), field("code")], proposingType: Self.sqlType)

        #expect(try settings(of: "amount", in: draft).type == "REAL")
        #expect(try settings(of: "code", in: draft).name == "sku")
    }

    @Test("Fields follow the new read: a vanished one is dropped, a new one is proposed, order is the file's")
    func fieldsFollowTheNewRead() throws {
        var draft = makeDraft([field("a"), field("b"), field("c")])
        try edit("b", in: &draft) { $0.name = "renamed" }
        try edit("c", in: &draft) { $0.isPrimaryKey = true }

        draft.load(fields: [field("d"), field("b"), field("a")], proposingType: Self.sqlType)

        #expect(draft.fields == ["d", "b", "a"])
        #expect(try settings(of: "d", in: draft) == .proposed(name: "d", type: "TEXT"))
        #expect(try settings(of: "b", in: draft).name == "renamed")
    }

    @Test("The CREATE covers the included, named columns with their keys and defaults")
    func definitionCoversIncludedColumns() throws {
        var draft = makeDraft([field("id", .integer), field("name"), field("skip"), field("blank")])
        try edit("id", in: &draft) {
            $0.isPrimaryKey = true
            $0.isNullable = false
        }
        try edit("name", in: &draft) { $0.defaultValue = "'x'" }
        try edit("skip", in: &draft) { $0.include = false }
        try edit("blank", in: &draft) { $0.name = "  " }

        let definition = try #require(draft.definition(tableName: "people"))

        #expect(definition.tableName == "people")
        #expect(definition.columns.map(\.name) == ["id", "name"])
        #expect(definition.columns.map(\.dataType) == ["INTEGER", "TEXT"])
        #expect(definition.columns.map(\.isNullable) == [false, true])
        #expect(definition.columns.map(\.defaultValue) == [nil, "'x'"])
        #expect(definition.primaryKeyColumns == ["id"])
        #expect(draft.columnMapping == ["id": "id", "name": "name"])
        #expect(draft.fields == ["id", "name", "skip", "blank"])
    }

    @Test("Nothing to create when no included column has a name")
    func noDefinitionWithoutANamedColumn() throws {
        var draft = makeDraft([field("a")])
        try edit("a", in: &draft) { $0.include = false }

        #expect(draft.definition(tableName: "t") == nil)
        #expect(!draft.hasNamedColumn)
        #expect(draft.columnMapping.isEmpty)
    }

    @Test("An included column without a name, or two sharing one in any case, is a problem")
    func columnNameProblems() throws {
        var draft = makeDraft([field("a"), field("b")])
        #expect(draft.problem == nil)

        try edit("b", in: &draft) { $0.name = " " }
        #expect(draft.problem == .unnamedColumn)

        try edit("b", in: &draft) { $0.name = "A" }
        #expect(draft.problem == .duplicateName)

        try edit("b", in: &draft) { $0.include = false }
        #expect(draft.problem == nil)
    }

    @Test("Including every column is one switch, and it reads as on only when every column is in")
    func includeEveryColumn() throws {
        var draft = makeDraft([field("a"), field("b")])
        #expect(draft.includesEveryColumn)

        draft.setAllIncluded(false)
        #expect(!draft.includesEveryColumn)
        #expect(draft.columns.allSatisfy { !$0.settings.include })

        draft.setAllIncluded(true)
        #expect(draft.includesEveryColumn)
        #expect(!NewTableDraft().includesEveryColumn)
    }
}
