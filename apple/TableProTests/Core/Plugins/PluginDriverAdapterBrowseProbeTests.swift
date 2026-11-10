//
//  PluginDriverAdapterBrowseProbeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class SchemaAwareBrowseDriver: PluginDriverStub, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }
    private(set) var browsedTables: [String] = []

    func buildBrowseQuery(
        table: String,
        schema: String?,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        browsedTables.append(table)
        return "READ \(table) LIMIT \(limit)"
    }

    func ping() async throws {}
}

private final class LegacyBrowseDriver: PluginDriverStub, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        "READ \(table)"
    }

    func ping() async throws {}
}

private final class HostBrowsedDriver: PluginDriverStub, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func ping() async throws {}
}

@MainActor
struct PluginDriverAdapterBrowseProbeTests {
    private func makeAdapter(_ driver: any PluginDatabaseDriver) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: TestFixtures.makeConnection(), pluginDriver: driver)
    }

    @Test("A driver that builds its browse only through the schema-aware overload builds the app's queries")
    func schemaAwareOverloadCounts() {
        let driver = SchemaAwareBrowseDriver()
        let adapter = makeAdapter(driver)

        #expect(adapter.queryBuildingPluginDriver === driver)
        #expect(adapter.rowWritingPluginDriver === driver)
        #expect(PluginDriverAdapter.buildsBrowseQueries(driver))
    }

    @Test("The table browse of a schema-aware driver is the driver's own statement")
    func tableQueryComesFromTheDriver() {
        let driver = SchemaAwareBrowseDriver()
        let adapter = makeAdapter(driver)

        let query = adapter.queryBuildingPluginDriver?.buildBrowseQuery(
            table: "events", schema: nil, sortColumns: [], columns: [], limit: 50, offset: 0
        )

        #expect(query == "READ events LIMIT 50")
    }

    @Test("A driver that answered once is not asked again on every read")
    func probesOnce() {
        let driver = SchemaAwareBrowseDriver()
        let adapter = makeAdapter(driver)

        for _ in 0 ..< 5 {
            #expect(adapter.queryBuildingPluginDriver != nil)
        }

        #expect(driver.browsedTables == ["_probe"])
    }

    @Test("A driver with only the older overload still builds the app's queries")
    func legacyOverloadStillCounts() {
        let driver = LegacyBrowseDriver()

        #expect(makeAdapter(driver).queryBuildingPluginDriver === driver)
    }

    @Test("A driver that leaves browsing to the app builds nothing")
    func hostBrowsedDriverBuildsNothing() {
        let adapter = makeAdapter(HostBrowsedDriver())

        #expect(adapter.queryBuildingPluginDriver == nil)
        #expect(adapter.rowWritingPluginDriver == nil)
    }
}
