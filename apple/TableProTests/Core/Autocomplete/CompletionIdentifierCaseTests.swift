import Foundation
@testable import TablePro
import TableProAutocomplete
import TableProPluginKit
import Testing

@MainActor
struct CompletionIdentifierCaseTests {
    private func makeEngine(_ type: DatabaseType) async -> CompletionEngine {
        let provider = SQLSchemaProvider(metadataSource: SQLSchemaProvider.ColumnMetadataSource(
            fetchColumns: { table, _ in
                guard table.uppercased() == "MY_TABLE" else { return [] }
                return [
                    TestFixtures.makeColumnInfo(name: "ORDER_ID"),
                    TestFixtures.makeColumnInfo(name: "CreatedAt"),
                ]
            },
            fetchAllColumns: { [:] }
        ))
        await provider.updateTables([
            TestFixtures.makeTableInfo(name: "MY_TABLE"),
            TestFixtures.makeTableInfo(name: "MixedCase"),
        ])
        return CompletionEngine(schemaProvider: provider, databaseType: type)
    }

    private func inserted(
        _ text: String,
        cursor: Int? = nil,
        type: DatabaseType = .snowflake,
        identifierCase: SQLIdentifierCase
    ) async -> [String] {
        let engine = await makeEngine(type)
        let context = await engine.getCompletions(
            text: text,
            cursorPosition: cursor ?? (text as NSString).length,
            identifierCase: identifierCase
        )
        return context?.items.map(\.insertText) ?? []
    }

    @Test("On Snowflake, matching the typing completes my_t to my_table and keeps a mixed-case table quoted")
    func snowflakeMatchesTheTyping() async {
        let lowered = await inserted("select * from my_t", identifierCase: .matchTyped)
        #expect(lowered.contains("my_table"))
        #expect(!lowered.contains("MY_TABLE"))

        let mixed = await inserted("select * from mix", identifierCase: .matchTyped)
        #expect(mixed.contains("\"MixedCase\""))
    }

    @Test("As stored keeps the stored spelling, and quotes only what bare would not reach")
    func asStoredKeepsTheSpelling() async {
        #expect(await inserted("select * from my_t", identifierCase: .asStored).contains("MY_TABLE"))
        #expect(await inserted("select * from mix", identifierCase: .asStored).contains("\"MixedCase\""))
    }

    @Test("Columns follow the setting after a table and a dot")
    func columnsAfterADot() async {
        let columns = await inserted("select my_table.ord", identifierCase: .lower)
        #expect(columns.contains("order_id"))

        let mixed = await inserted("select my_table.cre", identifierCase: .lower)
        #expect(mixed.contains("\"CreatedAt\""))
    }

    @Test("Inside a closed quote the stored name goes in raw")
    func insideAClosedQuote() async {
        let text = "select * from \"my_t\""
        let items = await inserted(text, cursor: (text as NSString).length - 1, identifierCase: .lower)
        #expect(items.contains("MY_TABLE"))
        #expect(!items.contains("\"MY_TABLE\""))
    }

    @Test("Re-ranking an open session spells the names the same way")
    func reRankingSpells() async throws {
        let engine = await makeEngine(.snowflake)
        let text = "select * from my"
        let context = try #require(await engine.getCompletions(
            text: text,
            cursorPosition: (text as NSString).length,
            identifierCase: .lower
        ))
        let ranked = engine.rank(
            context.candidates,
            prefix: "my_ta",
            context: context.sqlContext,
            keywordCase: .default,
            identifierCase: .lower
        )
        #expect(ranked.map(\.insertText).contains("my_table"))
    }

    @Test("An engine without identifier rules is untouched")
    func engineWithoutRules() async {
        let items = await inserted("select * from mix", type: .mysql, identifierCase: .lower)
        #expect(items.contains("MixedCase"))
    }

    @Test("PostgreSQL, PGlite, Oracle and Snowflake carry their folding; MySQL has none")
    func curatedRules() {
        #expect(DatabaseType.postgresql.identifierRules?.folding == .lower)
        #expect(DatabaseType.pglite.identifierRules?.folding == .lower)
        #expect(DatabaseType.oracle.identifierRules?.folding == .upper)
        #expect(DatabaseType.snowflake.identifierRules?.folding == .upper)
        #expect(DatabaseType.mysql.identifierRules == nil)
        #expect(DatabaseType.postgresql.identifierRules?.reservedWords.contains("USER") == true)
    }

    @Test("An Oracle column named after a clock value or pseudocolumn stays quoted")
    func oracleBuiltInValuesStayQuoted() throws {
        let rules = try #require(DatabaseType.oracle.identifierRules)
        let spelling = SQLIdentifierSpelling(rules: rules, policy: .lower)
        for name in ["CURRENT_DATE", "SYSTIMESTAMP", "ORA_ROWSCN", "ROWNUM", "USER"] {
            #expect(spelling.form(of: name) == .quoted, "\(name)")
        }
        let quote: (String) -> String = { "\"\($0)\"" }
        #expect(spelling.statementName("CURRENT_DATE", quotedBy: quote) == "\"CURRENT_DATE\"")
    }

    @Test("A cached table in another schema keeps its own spelling, not a namesake's")
    func cachedTableSpellingIsPerSchema() async throws {
        let driver = MockDatabaseDriver()
        driver.currentSchema = "public"
        driver.allColumnsToReturn = ["Orders": [TestFixtures.makeColumnInfo(name: "id")]]
        driver.columnsToReturn = ["orders": [TestFixtures.makeColumnInfo(name: "id")]]
        let provider = SQLSchemaProvider()
        await provider.resetForDatabase(
            "db",
            tables: [
                TestFixtures.makeTableInfo(name: "Orders", schema: "public"),
                TestFixtures.makeTableInfo(name: "orders", schema: "sales"),
            ],
            driver: driver
        )
        await provider.requestColumnPreload()
        await provider.waitForEagerColumnLoad()
        _ = await provider.getColumns(for: "orders", schema: "sales")

        let rules = try #require(DatabaseType.postgresql.identifierRules)
        let items = SQLIdentifierSpelling(rules: rules, policy: .asStored).applied(
            to: await provider.allColumnsFromCachedTables(),
            typedPrefix: "",
            quoting: .none
        )

        #expect(Set(items.map(\.insertText)) == ["\"Orders\".id", "sales.orders.id"])
    }

    @Test("The rules survive a plugin registering over the curated entry")
    func rulesSurvivePluginRegistration() {
        let built = PluginMetadataRegistry.shared.buildMetadataSnapshot(from: IdentifierRulesSnowflakePlugin.self)
        #expect(built.schema.identifierRules?.folding == .upper)
    }

    @Test("The setting is stored only when it differs from As stored")
    func settingRoundTrips() {
        var connection = DatabaseConnection(name: "Snowflake", type: .snowflake)
        #expect(connection.completionIdentifierCase == .asStored)

        connection.completionIdentifierCase = .matchTyped
        #expect(connection.additionalFields[DatabaseConnection.completionIdentifierCaseKey] == "matchTyped")
        #expect(connection.completionIdentifierCase == .matchTyped)

        connection.completionIdentifierCase = .asStored
        #expect(connection.additionalFields[DatabaseConnection.completionIdentifierCaseKey] == nil)
    }
}

private final class IdentifierRulesSnowflakePlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock Snowflake"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Stands in for the registry-distributed Snowflake plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Snowflake"
    static let databaseDisplayName = "Snowflake"
    static let iconName = "snowflake-icon"
    static let defaultPort = 443

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}
