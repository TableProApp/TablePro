// A diagram's key writes a schema named `default` and no schema alike, so a Trino `hive.default`
// diagram was unbound and followed the sidebar's browse schema on refresh and on Save.

import Foundation
@testable import TablePro
import Testing

@MainActor
struct ERDiagramSchemaBindingTests {
    private func connectBrowsing(schema: String) -> DatabaseConnection {
        let connection = TestFixtures.makeConnection(database: "hive", type: .duckdb)
        let driver = ERDiagramCatalogDriver(
            connection: connection,
            columns: [CatalogName("events"): [TestFixtures.makeColumnInfo(name: "id", isPrimaryKey: true)]],
            holds: [],
            failingReads: 0
        )
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = connection.database
        session.browseSchema = schema
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection
    }

    @Test("A diagram tab opened on the schema named default stays on it while the sidebar browses another")
    func recordedDefaultSchemaBindsTheDiagram() throws {
        let connection = connectBrowsing(schema: "staging")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let tabManager = QueryTabManager()
        tabManager.addERDiagramTab(
            schemaKey: ERDiagramViewModel.schemaKey(databaseName: "hive", schema: "default"),
            databaseName: "hive",
            schemaName: "default"
        )
        let tab = try #require(tabManager.selectedTab)

        let viewModel = ERDiagramViewModel(tab: tab, connection: connection)

        #expect(viewModel.schemaName == "default")
        #expect(viewModel.scope?.schema == "default")
    }

    @Test("Refresh and staged edits keep the schema the diagram loaded after the sidebar moves")
    func loadFixesTheScope() async throws {
        let connection = connectBrowsing(schema: "default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let viewModel = ERDiagramViewModel(
            connectionId: connection.id,
            databaseName: "hive",
            schemaKey: "hive.default",
            connection: connection
        )
        await viewModel.loadDiagram()
        try #require(viewModel.loadState == .loaded)

        DatabaseManager.shared.updateSession(connection.id) { $0.browseSchema = "staging" }

        #expect(viewModel.scope?.schema == "default")
        #expect(viewModel.edits?.schemaName == "default")
    }
}
