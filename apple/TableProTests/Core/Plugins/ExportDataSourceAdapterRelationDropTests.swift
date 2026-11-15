//
//  ExportDataSourceAdapterRelationDropTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct RelationDropCall: Equatable {
    let name: String
    let kind: PluginExportObjectKind
    let schema: String?
}

private final class RelationDropDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [RelationDropCall] = []

    var dropCalls: [RelationDropCall] { lock.withLock { calls } }

    func generateDropRelationSQL(name: String, kind: PluginExportObjectKind, schema: String?) -> String? {
        lock.withLock { calls.append(RelationDropCall(name: name, kind: kind, schema: schema)) }
        return "GUARDED DROP \(kind.rawValue) \(name)"
    }
}

private final class GenericDropDriver: PluginDriverStub, @unchecked Sendable {}

struct ExportDataSourceAdapterRelationDropTests {
    private func source(_ pluginDriver: any PluginDatabaseDriver) -> ExportDataSourceAdapter {
        let driver = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .oracle), pluginDriver: pluginDriver)
        return ExportDataSourceAdapter(driver: driver, databaseType: .oracle)
    }

    private func object(_ name: String, kind: PluginExportObjectKind) -> PluginExportTable {
        PluginExportTable(name: name, databaseName: "APP", tableType: kind.rawValue, schema: "APP", kind: kind)
    }

    @Test("A table, view or materialized view drops the way the driver spells it", arguments: [
        PluginExportObjectKind.table, .view, .materializedView,
    ])
    func driverSpellsTheRelationDrop(kind: PluginExportObjectKind) {
        let driver = RelationDropDriver()

        #expect(source(driver).dropStatement(for: object("ORDERS", kind: kind)) == "GUARDED DROP \(kind.rawValue) ORDERS")
        #expect(driver.dropCalls == [RelationDropCall(name: "ORDERS", kind: kind, schema: "APP")])
    }

    @Test("A driver with no relation drop leaves the export its own", arguments: [
        PluginExportObjectKind.table, .view, .materializedView,
    ])
    func driverWithoutRelationDropFallsBack(kind: PluginExportObjectKind) {
        #expect(source(GenericDropDriver()).dropStatement(for: object("ORDERS", kind: kind)) == nil)
    }

    @Test("Another kind never asks for a relation drop")
    func otherKindsAreNotAsked() {
        let driver = RelationDropDriver()

        #expect(source(driver).dropStatement(for: object("SEQ", kind: .sequence)) == nil)
        #expect(driver.dropCalls.isEmpty)
    }
}
