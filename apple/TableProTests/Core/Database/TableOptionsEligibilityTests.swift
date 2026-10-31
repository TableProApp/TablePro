//
//  TableOptionsEligibilityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class NoOptionsDriver: PluginDriverStub, @unchecked Sendable {}

private final class TableOptionsDriver: PluginDriverStub, @unchecked Sendable {
    private let writesOptions: Bool

    init(writesOptions: Bool) {
        self.writesOptions = writesOptions
    }

    func tableOptionsStatement(table: String, schema: String?, change: PluginTableOptionsChange) -> String? {
        writesOptions ? "ALTER TABLE \(table) DEFAULT CHARACTER SET \(change.characterSet ?? "")" : nil
    }

    func fetchTableOptions(table: String, schema: String?) async throws -> PluginTableOptions? {
        PluginTableOptions(characterSet: "latin1", collation: "latin1_swedish_ci", autoIncrement: 42)
    }

    func fetchTableOptionsCatalog() async throws -> PluginTableOptionsCatalog? {
        PluginTableOptionsCatalog(
            characterSets: [
                PluginCharacterSet(
                    name: "utf8mb4", defaultCollation: "utf8mb4_0900_ai_ci",
                    collations: ["utf8mb4_0900_ai_ci", "utf8mb4_bin"], description: "UTF-8 Unicode"
                )
            ],
            engines: ["InnoDB", "MyISAM"],
            defaultEngine: "InnoDB"
        )
    }

    func fetchDefaultTableOptions(schema: String?) async throws -> PluginTableOptions? {
        PluginTableOptions(characterSet: "utf8mb4", collation: "utf8mb4_0900_ai_ci")
    }
}

@MainActor
struct TableOptionsEligibilityTests {
    private func adapter(writesOptions: Bool) -> PluginDriverAdapter {
        PluginDriverAdapter(
            connection: TestFixtures.makeConnection(database: "shop", type: .mysql),
            pluginDriver: TableOptionsDriver(writesOptions: writesOptions)
        )
    }

    @Test("A driver with a table options statement offers them on tables and nowhere else")
    func offeredOnTablesOfADriverThatWritesThem() {
        let driver = adapter(writesOptions: true)

        #expect(DatabaseObjectToolEligibility.offersTableOptions(driver: driver, objectKind: .table))
        #expect(DatabaseObjectToolEligibility.offersTableOptions(driver: driver, objectKind: .partitionedTable))
        #expect(!DatabaseObjectToolEligibility.offersTableOptions(driver: driver, objectKind: .view))
        #expect(!DatabaseObjectToolEligibility.offersTableOptions(driver: driver, objectKind: .materializedView))
    }

    @Test("A driver without the statement, or no driver, offers none")
    func notOfferedWithoutTheStatement() {
        #expect(!DatabaseObjectToolEligibility.offersTableOptions(driver: adapter(writesOptions: false), objectKind: .table))
        #expect(!DatabaseObjectToolEligibility.offersTableOptions(driver: nil, objectKind: .table))
    }

    @Test("The adapter maps the plugin's options and catalog")
    func adapterMapsOptionsAndCatalog() async throws {
        let driver = adapter(writesOptions: true)

        let options = try await driver.fetchTableOptions(tableName: "orders")
        let catalog = try #require(try await driver.fetchTableOptionsCatalog())
        let defaults = try await driver.fetchDefaultTableOptions(schema: "shop")

        #expect(options == TableOptions(characterSet: "latin1", collation: "latin1_swedish_ci", autoIncrement: 42))
        #expect(catalog.characterSets == [TableCharacterSet(
            name: "utf8mb4", defaultCollation: "utf8mb4_0900_ai_ci",
            collations: ["utf8mb4_0900_ai_ci", "utf8mb4_bin"], description: "UTF-8 Unicode"
        )])
        #expect(catalog.engines == ["InnoDB", "MyISAM"])
        #expect(catalog.defaultEngine == "InnoDB")
        #expect(defaults == TableOptions(characterSet: "utf8mb4", collation: "utf8mb4_0900_ai_ci"))
    }

    @Test("An engine with no table options reads nil through the adapter")
    func engineWithoutOptionsReadsNil() async throws {
        let driver = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: NoOptionsDriver()
        )

        #expect(try await driver.fetchTableOptions(tableName: "orders") == nil)
        #expect(try await driver.fetchTableOptionsCatalog() == nil)
        #expect(driver.tableOptionsStatement(
            tableName: "orders", schema: nil, change: PluginTableOptionsChange(autoIncrement: 5)
        ) == nil)
    }
}
