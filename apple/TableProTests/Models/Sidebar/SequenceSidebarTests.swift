//
//  SequenceSidebarTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct SequenceSidebarTests {
    private func sequence(owner: (String, String)? = ("orders", "id")) -> TableInfo {
        TableInfo(
            name: "orders_id_seq", type: .sequence, rowCount: nil, schema: "public",
            ownedByTable: owner?.0, ownedByColumn: owner?.1
        )
    }

    @Test("A sequence gets a Sequences section of its own rather than joining Tables")
    func sequenceResolvesToItsOwnKind() {
        #expect(SidebarObjectKind.resolve(tableType: .sequence) == .sequence)
        #expect(SidebarObjectKind.sequence.category == .table)
        #expect(SidebarObjectKind.sequence.pluralDisplayName == String(localized: "Sequences"))
        #expect(SidebarObjectKind.visible(itemCounts: [.table: 1, .sequence: 2]) == [.table, .sequence])
    }

    @Test("A sequence's owning column is named on hover and to VoiceOver")
    func ownerIsDescribed() {
        let owner = String(format: String(localized: "Owned by %@"), "orders.id")
        #expect(TableRowLogic.ownerDescription(for: sequence()) == owner)
        #expect(TableRowLogic.accessibilityLabel(table: sequence(), isPendingDelete: false, isPendingTruncate: false)
            .hasSuffix(", " + owner))
        #expect(TableRowLogic.ownerDescription(for: sequence(owner: nil)) == nil)
    }

    @Test("The owner is not part of a sequence's identity")
    func ownerIsOutsideIdentity() {
        #expect(sequence() == sequence(owner: nil))
    }

    @Test("A sequence exported from the sidebar is preselected as a sequence")
    func exportPreselectsASequence() {
        let preselection = ExportPreselection.tables(names: ["orders_id_seq"], scope: nil)
        #expect(preselection.selects(
            object: "orders_id_seq", kind: .sequence, inContainer: .database("app"), isCurrentContainer: true
        ))
    }

    @Test("Compare and Copy To leave a listed sequence out of their table paths")
    func compareSkipsSequences() {
        #expect(CompareTableKindClassifier.isSequence(PluginTableInfo(name: "s", type: "SEQUENCE", comment: nil)))
        #expect(!CompareTableKindClassifier.isSequence(PluginTableInfo(name: "t", type: "BASE TABLE", comment: nil)))
    }
}

struct SequenceSettingsDraftTests {
    private let settings = PluginSequenceSettings(increment: 1, minValue: 1, maxValue: 100, cacheSize: 1, cycles: false)

    @Test("A draft seeded from the settings reads back the same settings")
    func roundTrip() {
        #expect(SequenceSettingsDraft(settings).settings == .success(settings))
    }

    @Test("Each impossible combination is named before the server is asked")
    func validation() {
        var draft = SequenceSettingsDraft(settings)
        draft.increment = "1.5"
        #expect(draft.settings == .failure(.notANumber))
        draft = SequenceSettingsDraft(settings)
        draft.increment = "0"
        #expect(draft.settings == .failure(.zeroIncrement))
        draft = SequenceSettingsDraft(settings)
        draft.minValue = "100"
        #expect(draft.settings == .failure(.minimumNotBelowMaximum))
        draft = SequenceSettingsDraft(settings)
        draft.cacheSize = "0"
        #expect(draft.settings == .failure(.cacheBelowOne))
    }

    @Test("Surrounding spaces are not a reason to refuse a number")
    func trimsSpaces() {
        #expect(SequenceSettingsDraft.number(" -42 ") == -42)
        #expect(SequenceSettingsDraft.number("9223372036854775808") == nil)
    }
}

private final class SequenceListingDriver: PluginDriverStub, @unchecked Sendable {
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { "public" }
    var serverVersion: String? { nil }

    var tables: [PluginTableInfo] = []
    var sequences: [PluginSequenceInfo] = []

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { tables }
    func fetchSequences(schema: String?) async throws -> [PluginSequenceInfo] { sequences }
    func ping() async throws {}
}

struct SequenceListingConsumerTests {
    private func adapter(_ driver: SequenceListingDriver) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: DatabaseConnection(name: "Test", type: .postgresql), pluginDriver: driver)
    }

    @Test("The listing's owner reaches the sidebar's TableInfo")
    func adapterCarriesTheOwner() async throws {
        let driver = SequenceListingDriver()
        driver.tables = [PluginTableInfo(
            name: "orders_id_seq", type: "SEQUENCE", schema: "public", comment: nil, partitionCount: nil,
            ownedByTable: "orders", ownedByColumn: "id"
        )]
        let tables = try await adapter(driver).fetchTables()
        let table = try #require(tables.first)
        #expect(table.type == .sequence)
        #expect(table.ownedByTable == "orders")
        #expect(table.ownedByColumn == "id")
    }

    @Test("A sequence the driver also lists as a sequence is exported once, as a sequence")
    func exportWritesASequenceOnce() async {
        let driver = SequenceListingDriver()
        driver.sequences = [PluginSequenceInfo(name: "orders_id_seq", ddl: "CREATE SEQUENCE \"orders_id_seq\";")]
        let tables = [
            TableInfo(name: "orders", type: .table, rowCount: nil),
            TableInfo(name: "orders_id_seq", type: .sequence, rowCount: nil)
        ]
        let items = await ExportObjectLoader.loadObjects(
            request: .init(containerName: "public", schema: "public", kinds: [.table, .sequence]),
            tables: tables,
            driver: adapter(driver)
        )
        #expect(items.filter { $0.name == "orders_id_seq" }.map(\.kind) == [.sequence])
        #expect(items.contains { $0.name == "orders" && $0.kind == .table })
    }

    @Test("A format that writes no sequences leaves them out instead of exporting their state row")
    func rowFormatsSkipSequences() async {
        let driver = SequenceListingDriver()
        let items = await ExportObjectLoader.loadObjects(
            request: .init(containerName: "public", schema: "public", kinds: [.table]),
            tables: [
                TableInfo(name: "orders", type: .table, rowCount: nil),
                TableInfo(name: "orders_id_seq", type: .sequence, rowCount: nil)
            ],
            driver: adapter(driver)
        )
        #expect(items.map(\.name) == ["orders"])
    }

    @Test("A sequence only the table listing knows, as on MariaDB, still exports as a table")
    func exportKeepsAnUnlistedSequence() async {
        let driver = SequenceListingDriver()
        let items = await ExportObjectLoader.loadObjects(
            request: .init(containerName: "app", schema: nil, kinds: [.table, .sequence]),
            tables: [TableInfo(name: "invoice_seq", type: .sequence, rowCount: nil)],
            driver: adapter(driver)
        )
        #expect(items.map(\.kind) == [.table])
    }
}

struct SequenceExportMergeTests {
    @Test("Expanding a collapsed schema replaces its table-listed sequence with the sequence itself")
    func mergeReplacesTheTableListedSequence() {
        let collapsed = ExportDatabaseItem(
            name: "public",
            objects: [
                ExportObjectItem(name: "orders", databaseName: "public", kind: .table, isSelected: true),
                ExportObjectItem(name: "orders_id_seq", databaseName: "public", kind: .table, isSelected: true)
            ],
            unloadedKinds: [.sequence]
        )
        let merged = collapsed.mergingLoadedObjects([
            ExportObjectItem(name: "orders_id_seq", databaseName: "public", kind: .sequence)
        ])

        #expect(merged.objects.filter { $0.name == "orders_id_seq" }.map(\.kind) == [.sequence])
        #expect(merged.objects.first { $0.name == "orders_id_seq" }?.isSelected == true)
        #expect(merged.objects.contains { $0.name == "orders" && $0.kind == .table })
    }
}
