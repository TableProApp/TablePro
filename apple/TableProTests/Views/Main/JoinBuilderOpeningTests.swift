import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct JoinBuilderOpeningTests {
    private func makeCoordinator(type: DatabaseType = .mysql) -> MainContentCoordinator {
        MainContentCoordinator(
            connection: TestFixtures.makeConnection(database: "shop", type: type),
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
    }

    private func launch(of coordinator: MainContentCoordinator) -> JoinBuilderLaunchRequest? {
        guard case .joinBuilder(let launch) = coordinator.activeSheet else { return nil }
        return launch
    }

    private func ref(_ name: String, database: String? = "shop", schema: String? = nil) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(database: database, schema: schema, table: TableInfo(name: name, type: .table, rowCount: nil))
    }

    @Test("The generated query opens in a new query tab on the builder's database and leaves the open tab alone")
    func openingTheQuery() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }
        var opened: [EditorTabPayload] = []
        coordinator.openTabInNewWindow = { opened.append($0) }
        coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "shop")
        coordinator.activeSheet = .joinBuilder(JoinBuilderLaunchRequest(database: "archive", schema: nil, tables: []))

        coordinator.openJoinQuery("SELECT *\nFROM \"orders\"", database: "archive")

        #expect(coordinator.activeSheet == nil)
        #expect(opened.count == 1)
        #expect(opened.first?.tabType == .query)
        #expect(opened.first?.initialQuery == "SELECT *\nFROM \"orders\"")
        #expect(opened.first?.databaseName == "archive")
        #expect(coordinator.tabManager.tabs.first?.content.query == "SELECT 1")
    }

    @Test("The sidebar selection seeds the builder with the tables that share the first one's schema")
    func sidebarSelectionSeeds() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }
        #expect(coordinator.canBuildJoinQuery)

        coordinator.openJoinBuilder(seededWith: [
            ref("orders"),
            ref("customers"),
            ref("accounts", database: "billing")
        ])

        let launch = try #require(launch(of: coordinator))
        #expect(launch.database == "billing")
        #expect(launch.tables == ["accounts"])

        coordinator.openJoinBuilder(seededWith: [ref("orders"), ref("customers")])
        let seeded = try #require(self.launch(of: coordinator))
        #expect(seeded.database == "shop")
        #expect(seeded.tables == ["customers", "orders"])
    }

    @Test("An empty selection opens the builder on the browsed database with nothing picked")
    func emptySelection() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.openJoinBuilder(seededWith: [])

        let launch = try #require(launch(of: coordinator))
        #expect(launch.tables.isEmpty)
        #expect(launch.schema == nil)
    }

    @Test("The sheet names the connection and the database, not a file-based engine's whole path")
    func scopeDescriptionUsesTheEndpointLabel() {
        let connection = TestFixtures.makeConnection(name: "Fixture", database: "/tmp/shop.sqlite", type: .sqlite)
        let model = JoinBuilderViewModel(
            launch: JoinBuilderLaunchRequest(database: "/tmp/shop.sqlite", schema: nil, tables: []),
            connection: connection
        )

        #expect(model.scopeDescription == DatabaseEndpoint.from(connection: connection, database: "/tmp/shop.sqlite").qualifiedDescription)
        #expect(!model.scopeDescription.contains("/tmp/"))
    }

    @Test("Only an engine with SQL and foreign keys gets the builder")
    func eligibility() {
        let dialect = SQLDialectDescriptor(identifierQuote: "\"", keywords: [], functions: [], dataTypes: [])

        #expect(JoinBuilderEligibility.supportsJoinBuilder(editorLanguage: .sql, dialect: dialect, supportsForeignKeys: true))
        #expect(!JoinBuilderEligibility.supportsJoinBuilder(editorLanguage: .sql, dialect: dialect, supportsForeignKeys: false))
        #expect(!JoinBuilderEligibility.supportsJoinBuilder(editorLanguage: .sql, dialect: nil, supportsForeignKeys: true))
        #expect(!JoinBuilderEligibility.supportsJoinBuilder(editorLanguage: .javascript, dialect: dialect, supportsForeignKeys: true))
    }
}
