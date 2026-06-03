//
//  PluginKitABIResilienceTests.swift
//  TableProTests
//
//  Guards the additive-safety promise of the resilient PluginKit ABI: a driver
//  that implements only the required surface and omits every defaulted
//  requirement must still satisfy the protocol, and each default must return its
//  documented value. If a requirement is ever added without a default, this file
//  (and FakeMSSQLPluginDriver) stops compiling, flagging a breaking change that
//  needs a currentPluginKitVersion bump. Cross-binary load compatibility itself
//  is enforced by scripts/check-pluginkit-abi.sh in CI.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("PluginKit ABI resilience")
struct PluginKitABIResilienceTests {
    private func makeMinimalDriver() -> any PluginDatabaseDriver {
        FakeMSSQLPluginDriver()
    }

    @Test("A driver that omits defaulted requirements falls back to the documented synchronous defaults")
    func synchronousDefaults() {
        let driver = makeMinimalDriver()
        #expect(driver.supportsTransactions == true)
        #expect(driver.serverVersion == nil)
        #expect(driver.capabilities.isEmpty)
        #expect(driver.foreignKeyDisableStatements() == nil)
        #expect(driver.foreignKeyEnableStatements() == nil)
        #expect(driver.supportedMaintenanceOperations() == nil)
        #expect(driver.buildExplainQuery("SELECT 1") == nil)
        #expect(driver.defaultExportQuery(table: "users") == nil)
        #expect(driver.createViewTemplate() == nil)
        #expect(driver.generateCreateTableSQL(definition: .init(tableName: "users", columns: [], primaryKeyColumns: [])) == nil)
    }

    @Test("A driver that omits defaulted requirements falls back to the documented asynchronous defaults")
    func asynchronousDefaults() async throws {
        let driver = makeMinimalDriver()
        #expect(try await driver.fetchSchemas().isEmpty)
        #expect(try await driver.fetchApproximateRowCount(table: "users", schema: nil) == nil)
    }
}
