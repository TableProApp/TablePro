//
//  TableTransferServiceTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Table transfer")
struct TableTransferServiceTests {

    @Test("A row is keyed by its header's column names, in order")
    func rowIsKeyedByHeader() {
        let values = TableTransferService.dictionary(
            columns: ["id", "name", "email"],
            row: [.text("1"), .text("Ada"), .text("ada@example.com")]
        )
        #expect(values.count == 3)
        #expect(values["id"] == .text("1"))
        #expect(values["name"] == .text("Ada"))
        #expect(values["email"] == .text("ada@example.com"))
    }

    /// A driver that stops sending values once the rest of a row is null would otherwise lose the
    /// whole row: the sink writes by column name, and a missing key is not a null.
    @Test("A row shorter than its header is padded with nulls")
    func shortRowIsPadded() {
        let values = TableTransferService.dictionary(
            columns: ["id", "name", "email"],
            row: [.text("1")]
        )
        #expect(values.count == 3)
        #expect(values["id"] == .text("1"))
        #expect(values["name"] == .null)
        #expect(values["email"] == .null)
    }

    @Test("A row longer than its header keeps only the named columns")
    func extraValuesAreDropped() {
        let values = TableTransferService.dictionary(
            columns: ["id"],
            row: [.text("1"), .text("unnamed")]
        )
        #expect(values == ["id": .text("1")])
    }

    @Test("An empty header produces no values")
    func emptyHeaderProducesNothing() {
        #expect(TableTransferService.dictionary(columns: [], row: [.text("1")]).isEmpty)
    }

    @Test("Binary and null values survive the transfer unchanged")
    func binaryAndNullSurvive() {
        let payload = Data([0x00, 0xFF, 0x10])
        let values = TableTransferService.dictionary(
            columns: ["blob", "missing"],
            row: [.bytes(payload), .null]
        )
        #expect(values["blob"] == .bytes(payload))
        #expect(values["missing"] == .null)
    }

    /// The transfer moves rows, so a request naming only definition objects has nothing to do and
    /// must say so rather than reporting a successful transfer of nothing.
    @MainActor @Test("A request with no row-carrying object is refused")
    func requestWithoutTablesIsRefused() {
        let service = TableTransferService()
        let request = TableTransferService.Request(
            objects: [
                ExportObjectItem(name: "recalc", kind: .routine),
                ExportObjectItem(name: "audit", kind: .trigger, parentTable: "users")
            ],
            sourceType: .postgresql,
            destinationType: .postgresql
        )
        #expect(request.objects.allSatisfy { !$0.kind.carriesRows })
        #expect(service.state.isTransferring == false)
    }

    @Test("A request keeps the row scope of every object it names")
    func requestKeepsRowScope() {
        let scoped = ExportObjectItem(
            name: "users",
            kind: .table,
            isSelected: true,
            rowScope: PluginExportRowScope(filter: "active", rowLimit: 10)
        )
        let request = TableTransferService.Request(
            objects: [scoped], sourceType: .mysql, destinationType: .postgresql)
        #expect(request.objects[0].rowScope.sanitizedFilter == "active")
        #expect(request.objects[0].rowScope.rowLimit == 10)
    }

    @Test("Transactions and row deletion default to the safe choice")
    func requestDefaults() {
        let request = TableTransferService.Request(
            objects: [], sourceType: .mysql, destinationType: .mysql)
        #expect(request.wrapInTransaction)
        #expect(!request.deleteExistingRows)
    }
}
