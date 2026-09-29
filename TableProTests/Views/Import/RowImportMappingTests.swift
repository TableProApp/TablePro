//
//  RowImportMappingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct RowImportMappingTests {
    private let columns = ["id", "full_name", "email"]
    private let people = TableScope(connectionId: UUID(), database: "shop", schema: nil, table: "people")

    private func makeStore() throws -> ImportColumnMappingStore {
        let defaults = try #require(UserDefaults(suiteName: "RowImportMappingTests.\(UUID().uuidString)"))
        return ImportColumnMappingStore(defaults: defaults)
    }

    private func fields(_ names: [String]) -> [PluginImportField] {
        names.map { PluginImportField(name: $0, sampleValue: nil, inferredType: .text) }
    }

    private func mapped(_ mapping: RowImportMapping) -> [String?] {
        mapping.rows.map(\.choice.mappedColumn)
    }

    private func rememberShown(_ mapping: RowImportMapping, in scope: TableScope) {
        mapping.remember(
            fields: mapping.fields,
            columns: mapping.columns,
            columnMapping: mapping.columnMapping,
            in: scope
        )
    }

    private func pick(_ column: String?, for field: String, in mapping: RowImportMapping) throws {
        let index = try #require(mapping.rows.firstIndex { $0.field.name == field })
        mapping.rows[index].choice = ImportFieldChoice(include: column != nil, column: column)
    }

    @Test("The mapping picked for a table comes back the next time a file goes into it")
    func pickedMappingComesBack() throws {
        let store = try makeStore()
        let first = RowImportMapping(store: store)
        first.load(fields: fields(["id", "Name", "E-mail"]), columns: columns, for: people)
        #expect(mapped(first) == ["id", nil, nil])
        #expect(first.showsSavedMapping == false)

        try pick("full_name", for: "Name", in: first)
        try pick("email", for: "E-mail", in: first)
        rememberShown(first, in: people)

        let second = RowImportMapping(store: store)
        second.load(fields: fields(["id", "Name", "E-mail"]), columns: columns, for: people)

        #expect(mapped(second) == ["id", "full_name", "email"])
        #expect(second.showsSavedMapping)
    }

    @Test("Reading the file again keeps the columns picked in this sheet")
    func reloadKeepsSessionChoices() throws {
        let mapping = RowImportMapping(store: try makeStore())
        mapping.load(fields: fields(["id", "Name"]), columns: columns, for: people)
        try pick("full_name", for: "Name", in: mapping)

        mapping.load(fields: fields(["id", "Name"]), columns: columns, for: people)

        #expect(mapped(mapping) == ["id", "full_name"])
    }

    @Test("A choice made in this sheet wins over the remembered one on a reload")
    func sessionChoiceBeatsRememberedOne() throws {
        let store = try makeStore()
        store.remember(["Name": .column("full_name")], forFields: ["Name"], in: people)
        let mapping = RowImportMapping(store: store)
        mapping.load(fields: fields(["Name"]), columns: columns, for: people)
        try pick("email", for: "Name", in: mapping)

        mapping.load(fields: fields(["Name"]), columns: columns, for: people)

        #expect(mapped(mapping) == ["email"])
    }

    @Test("Another table starts from its own remembered mapping, not this one's")
    func clearingForgetsTheSession() throws {
        let mapping = RowImportMapping(store: try makeStore())
        mapping.load(fields: fields(["Name"]), columns: columns, for: people)
        try pick("full_name", for: "Name", in: mapping)
        let customers = TableScope(connectionId: people.connectionId, database: "shop", schema: nil, table: "customers")

        mapping.clear()
        mapping.load(fields: fields(["Name"]), columns: columns, for: customers)

        #expect(mapped(mapping) == [nil])
    }

    @Test("Clearing the rows forgets what they were read for, so the same table is read again")
    func clearingForgetsTheRead() throws {
        let mapping = RowImportMapping(store: try makeStore())
        mapping.load(fields: fields(["id"]), columns: columns, for: people, read: AnyHashable("people"))
        #expect(mapping.loadedRead == AnyHashable("people"))

        mapping.clear()

        #expect(mapping.loadedRead == nil)
        #expect(mapping.rows.isEmpty)
    }

    @Test("Match by Name drops the remembered choices and Use Saved Mapping brings them back")
    func matchCommandsRewriteEveryRow() throws {
        let store = try makeStore()
        store.remember(["Name": .column("full_name")], forFields: ["Name"], in: people)
        let mapping = RowImportMapping(store: store)
        mapping.load(fields: fields(["id", "Name"]), columns: columns, for: people)

        mapping.matchByName()
        #expect(mapped(mapping) == ["id", nil])
        #expect(mapping.showsSavedMapping == false)
        #expect(mapping.canUseSavedMapping)

        mapping.useSavedMapping()
        #expect(mapped(mapping) == ["id", "full_name"])
        #expect(mapping.showsSavedMapping)
        #expect(mapping.canUseSavedMapping == false)
    }

    @Test("A mapping saved by an import that failed is not announced as restored when the file is read again")
    func ownMappingIsNotReportedAsRestored() throws {
        let mapping = RowImportMapping(store: try makeStore())
        mapping.load(fields: fields(["id", "Name"]), columns: columns, for: people)
        try pick("full_name", for: "Name", in: mapping)
        rememberShown(mapping, in: people)

        mapping.load(fields: fields(["id", "Name"]), columns: columns, for: people)

        #expect(mapped(mapping) == ["id", "full_name"])
        #expect(mapping.showsSavedMapping == false)
        #expect(mapping.canUseSavedMapping == false)
    }

    @Test("A restored mapping stays announced when the file is read again")
    func restoredMappingSurvivesAReload() throws {
        let store = try makeStore()
        store.remember(["Name": .column("full_name")], forFields: ["Name"], in: people)
        let mapping = RowImportMapping(store: store)
        mapping.load(fields: fields(["Name"]), columns: columns, for: people)

        mapping.load(fields: fields(["Name"]), columns: columns, for: people)

        #expect(mapping.showsSavedMapping)
    }

    @Test("Use Saved Mapping is off for a file that shares no field with the saved mapping")
    func savedMappingForAnotherLayoutIsNotOffered() throws {
        let store = try makeStore()
        store.remember(["Full Name": .column("full_name")], forFields: ["Full Name"], in: people)
        let mapping = RowImportMapping(store: store)
        mapping.load(fields: fields(["id", "email"]), columns: columns, for: people)
        try pick(nil, for: "email", in: mapping)

        #expect(mapping.canUseSavedMapping == false)
    }

    @Test("A column picked in this sheet wins over a saved choice for another field after a re-read")
    func sessionChoiceWinsOverSavedChoiceForAnotherField() throws {
        let store = try makeStore()
        store.remember(["legacy_email": .column("email")], forFields: ["legacy_email"], in: people)
        let mapping = RowImportMapping(store: store)
        mapping.load(fields: fields(["Column 1", "Column 2"]), columns: columns, for: people)
        try pick("email", for: "Column 2", in: mapping)

        mapping.load(fields: fields(["legacy_email", "Column 2"]), columns: columns, for: people)

        #expect(mapped(mapping) == [nil, "email"])
    }

    @Test("Match by Position pairs the fields with the columns in order")
    func matchByPosition() throws {
        let mapping = RowImportMapping(store: try makeStore())
        mapping.load(fields: fields(["Column 1", "Column 2", "Column 3"]), columns: columns, for: people)

        mapping.matchByPosition()

        #expect(mapped(mapping) == ["id", "full_name", "email"])
        #expect(mapping.columnMapping == ["Column 1": "id", "Column 2": "full_name", "Column 3": "email"])
    }

    @Test("Nothing is remembered for a table until an import into it starts")
    func nothingIsSavedBeforeImport() throws {
        let store = try makeStore()
        let mapping = RowImportMapping(store: store)
        mapping.load(fields: fields(["Name"]), columns: columns, for: people)
        try pick("full_name", for: "Name", in: mapping)

        #expect(store.overrides(for: people).isEmpty)
        #expect(mapping.canUseSavedMapping == false)
    }

    @Test("A new table remembers only the fields its columns were renamed from or left out")
    func createdTableRemembersRenames() throws {
        let store = try makeStore()
        let mapping = RowImportMapping(store: store)

        mapping.remember(
            fields: ["id", "E-mail", "notes"],
            columns: ["id", "email"],
            columnMapping: ["id": "id", "E-mail": "email"],
            in: people
        )

        #expect(store.overrides(for: people) == ["E-mail": .column("email")])
    }

    @Test("Two fields sent to one column are reported")
    func duplicateTargetIsReported() throws {
        let mapping = RowImportMapping(store: try makeStore())
        mapping.load(fields: fields(["email", "work_email"]), columns: columns, for: people)
        #expect(mapping.mapsOneColumnTwice == false)

        try pick("email", for: "work_email", in: mapping)

        #expect(mapping.mapsOneColumnTwice)
    }
}
