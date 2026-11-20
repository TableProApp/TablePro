import Foundation
@testable import TablePro
import Testing

struct SQLSchemaProviderCatalogTests {
    private static let users = TestFixtures.makeTableInfo(name: "users")
    private static let idColumn = [TestFixtures.makeColumnInfo(name: "id")]

    private static func completeDriver() -> MockDatabaseDriver {
        let driver = MockDatabaseDriver()
        driver.bulkColumnReadIsComplete = true
        driver.allColumnsToReturn = ["users": idColumn]
        return driver
    }

    private static func seeded(_ driver: MockDatabaseDriver, tables: [TableInfo] = [users]) async -> SQLSchemaProvider {
        let provider = SQLSchemaProvider()
        await provider.resetForDatabase("db", tables: tables, driver: driver)
        await provider.seedColumnCatalog()
        await provider.waitForEagerColumnLoad()
        return provider
    }

    private static func names(_ provider: SQLSchemaProvider, _ table: String) async -> [String]? {
        await provider.catalogColumns(forTable: table, schema: nil)?.map(\.name)
    }

    @Test("A seed reads every column once per table list without an editor asking, and answers only the listed spelling")
    func seedAnswersTheListedSpelling() async {
        let driver = Self.completeDriver()
        let provider = await Self.seeded(driver)

        #expect(await Self.names(provider, "users") == ["id"])
        #expect(await Self.names(provider, "USERS") == nil)
        #expect(driver.fetchAllColumnsCallCount == 1)

        await provider.seedColumnCatalog()
        await provider.waitForEagerColumnLoad()
        #expect(driver.fetchAllColumnsCallCount == 1)
    }

    @Test("A refresh of the same scope keeps nothing the grid may trust until the next seed has read it")
    func refreshedListIsAnsweredAfterItsOwnSeed() async {
        let driver = Self.completeDriver()
        let provider = await Self.seeded(driver)
        driver.allColumnsToReturn = ["users": [TestFixtures.makeColumnInfo(name: "id"), TestFixtures.makeColumnInfo(name: "email")]]

        await provider.resetForDatabase("db", tables: [Self.users], driver: driver)
        #expect(await Self.names(provider, "users") == nil)

        await provider.seedColumnCatalog()
        await provider.waitForEagerColumnLoad()
        #expect(driver.fetchAllColumnsCallCount == 2)
        #expect(await Self.names(provider, "users") == ["id", "email"])
    }

    @Test("A bulk read that can leave columns out is never started by a seed and never answers the grid")
    func incompleteBulkReadIsNotAnswered() async {
        let driver = Self.completeDriver()
        driver.bulkColumnReadIsComplete = false
        let provider = SQLSchemaProvider()
        await provider.resetForDatabase("db", tables: [Self.users], driver: driver)
        await provider.seedColumnCatalog()
        await provider.waitForEagerColumnLoad()
        #expect(driver.fetchAllColumnsCallCount == 0)

        await provider.requestColumnPreload()
        await provider.waitForEagerColumnLoad()
        #expect(driver.fetchAllColumnsCallCount == 1)
        #expect(await Self.names(provider, "users") == nil)
    }

    @Test("Two tables whose names differ only in case each answer their own columns")
    func caseOnlyNamesAnswerTheirOwnColumns() async {
        let driver = Self.completeDriver()
        driver.allColumnsToReturn = [
            "Users": [TestFixtures.makeColumnInfo(name: "upper_id")],
            "users": [TestFixtures.makeColumnInfo(name: "lower_id")]
        ]
        let provider = await Self.seeded(driver, tables: [TestFixtures.makeTableInfo(name: "Users"), Self.users])

        #expect(await Self.names(provider, "users") == ["lower_id"])
        #expect(await Self.names(provider, "Users") == ["upper_id"])
        #expect(await Self.names(provider, "USERS") == nil)
    }

    @Test("A completion read for another spelling of the name never answers the grid")
    func otherSpellingReadIsNotAnswered() async {
        let driver = Self.completeDriver()
        driver.allColumnsToReturn = [:]
        driver.columnsToReturn = ["users": Self.idColumn]
        let provider = await Self.seeded(driver)

        _ = await provider.getColumns(for: "USERS")

        #expect(await Self.names(provider, "users") == nil)
    }

    @Test("A completion read of a schema spelled in another case never answers for the listed one")
    func otherSchemaSpellingIsNotAnswered() async {
        let driver = Self.completeDriver()
        driver.currentSchema = "Sales"
        driver.columnsToReturn = ["users": [TestFixtures.makeColumnInfo(name: "other")]]
        let listed = [TestFixtures.makeTableInfo(name: "users", schema: "Sales")]
        let provider = await Self.seeded(driver, tables: listed)
        #expect(await provider.catalogColumns(forTable: "users", schema: "Sales")?.map(\.name) == ["id"])
        await provider.resetForDatabase("db", tables: listed, driver: driver)

        #expect(await provider.getColumns(for: "users", schema: "sales").map(\.name) == ["other"])

        #expect(await provider.catalogColumns(forTable: "users", schema: "Sales") == nil)
    }

    @Test("Discarded columns are no longer answered")
    func discardDropsTheEntry() async {
        let provider = await Self.seeded(Self.completeDriver())

        await provider.discardColumns(forTable: "users", schema: nil)

        #expect(await Self.names(provider, "users") == nil)
    }
}
