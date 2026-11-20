import Foundation
@testable import TablePro
import Testing

struct SQLSchemaProviderTwinTests {
    private static func column(_ name: String) -> [ColumnInfo] {
        [TestFixtures.makeColumnInfo(name: name)]
    }

    private static func seeded(_ driver: MockDatabaseDriver, tables: [TableInfo]) async -> SQLSchemaProvider {
        driver.bulkColumnReadIsComplete = true
        let provider = SQLSchemaProvider()
        await provider.resetForDatabase("db", tables: tables, driver: driver)
        await provider.seedColumnCatalog()
        await provider.waitForEagerColumnLoad()
        return provider
    }

    @Test("Two tables whose names differ only in Unicode form each keep their own columns")
    func twinTablesKeepTheirColumns() async {
        let driver = MockDatabaseDriver()
        driver.allColumnsToReturn = [
            CatalogName(TwinNames.composed): Self.column("a"),
            CatalogName(TwinNames.decomposed): Self.column("b")
        ]
        let provider = await Self.seeded(driver, tables: [
            TestFixtures.makeTableInfo(name: TwinNames.composed),
            TestFixtures.makeTableInfo(name: TwinNames.decomposed)
        ])

        #expect(await provider.getColumns(for: TwinNames.composed).map(\.name) == ["a"])
        #expect(await provider.getColumns(for: TwinNames.decomposed).map(\.name) == ["b"])
        #expect(await provider.catalogColumns(forTable: TwinNames.composed, schema: nil)?.map(\.name) == ["a"])
        #expect(await provider.catalogColumns(forTable: TwinNames.decomposed, schema: nil)?.map(\.name) == ["b"])
        #expect(driver.fetchColumnsCallCount == 0)
    }

    @Test("A typed name still finds the one listed table it names ignoring case")
    func typedNameMatchesIgnoringCase() async {
        let driver = MockDatabaseDriver()
        driver.allColumnsToReturn = ["orders": Self.column("id")]
        let provider = await Self.seeded(driver, tables: [TestFixtures.makeTableInfo(name: "orders")])

        #expect(await provider.getColumns(for: "ORDERS").map(\.name) == ["id"])
        #expect(driver.fetchColumnsCallCount == 0)
    }

    @Test("A table of a twin schema is not answered from the preloaded schema's namesake")
    func twinSchemasKeepTheirTables() async {
        let driver = MockDatabaseDriver()
        driver.currentSchema = TwinNames.composed
        driver.allColumnsToReturn = ["t": Self.column("preloaded")]
        driver.columnsToReturn = ["t": Self.column("own")]
        let provider = await Self.seeded(driver, tables: [
            TestFixtures.makeTableInfo(name: "t", schema: TwinNames.composed),
            TestFixtures.makeTableInfo(name: "t", schema: TwinNames.decomposed)
        ])

        #expect(await provider.getColumns(for: "t", schema: TwinNames.composed).map(\.name) == ["preloaded"])
        #expect(await provider.getColumns(for: "t", schema: TwinNames.decomposed).map(\.name) == ["own"])
        #expect(await provider.catalogColumns(forTable: "t", schema: TwinNames.decomposed)?.map(\.name) == ["own"])
    }
}
