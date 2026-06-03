import Foundation
@testable import TablePro
import Testing

@Suite("MainSplitViewController.resolveDefaultTitle")
@MainActor
struct MainSplitViewControllerTitleTests {
    @Test("Nil payload falls back to SQL Query")
    func nilPayloadFallsBackToSQLQuery() {
        let title = MainSplitViewController.resolveDefaultTitle(payload: nil, queryLanguageName: nil)
        #expect(title == String(localized: "SQL Query"))
    }

    @Test("Server dashboard payload returns Server Dashboard")
    func serverDashboardLabel() {
        let payload = EditorTabPayload(connectionId: UUID(), tabType: .serverDashboard)
        let title = MainSplitViewController.resolveDefaultTitle(payload: payload, queryLanguageName: "PostgreSQL")
        #expect(title == String(localized: "Server Dashboard"))
    }

    @Test("ER diagram payload returns ER Diagram")
    func erDiagramLabel() {
        let payload = EditorTabPayload(connectionId: UUID(), tabType: .erDiagram)
        let title = MainSplitViewController.resolveDefaultTitle(payload: payload, queryLanguageName: "PostgreSQL")
        #expect(title == String(localized: "ER Diagram"))
    }

    @Test("Create table payload returns Create Table")
    func createTableLabel() {
        let payload = EditorTabPayload(connectionId: UUID(), tabType: .createTable)
        let title = MainSplitViewController.resolveDefaultTitle(payload: payload, queryLanguageName: "PostgreSQL")
        #expect(title == String(localized: "Create Table"))
    }

    @Test("Explicit tabTitle wins")
    func explicitTabTitleWins() {
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .query,
            tabTitle: "report"
        )
        let title = MainSplitViewController.resolveDefaultTitle(payload: payload, queryLanguageName: "PostgreSQL")
        #expect(title == "report")
    }

    @Test("Source file URL resolves to file display name, not language fallback")
    func sourceFileURLBeatsLanguageFallback() {
        let url = URL(fileURLWithPath: "/tmp/report.sql")
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .query,
            sourceFileURL: url
        )
        let title = MainSplitViewController.resolveDefaultTitle(payload: payload, queryLanguageName: "PostgreSQL")
        #expect(title == QueryTab.fileDisplayTitle(for: url))
        #expect(title != "PostgreSQL Query")
        #expect(title != String(localized: "SQL Query"))
    }

    @Test("Explicit tabTitle takes precedence over sourceFileURL")
    func tabTitlePrecedesSourceFileURL() {
        let url = URL(fileURLWithPath: "/tmp/report.sql")
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .query,
            sourceFileURL: url,
            tabTitle: "Renamed"
        )
        let title = MainSplitViewController.resolveDefaultTitle(payload: payload, queryLanguageName: "PostgreSQL")
        #expect(title == "Renamed")
    }

    @Test("Source file URL takes precedence over tableName")
    func sourceFileURLPrecedesTableName() {
        let url = URL(fileURLWithPath: "/tmp/report.sql")
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .query,
            tableName: "users",
            sourceFileURL: url
        )
        let title = MainSplitViewController.resolveDefaultTitle(payload: payload, queryLanguageName: "PostgreSQL")
        #expect(title == QueryTab.fileDisplayTitle(for: url))
    }

    @Test("Table payload with tableName returns the table name")
    func tableNameUsedForTablePayload() {
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .table,
            tableName: "users"
        )
        let title = MainSplitViewController.resolveDefaultTitle(payload: payload, queryLanguageName: "PostgreSQL")
        #expect(title == "users")
    }

    @Test("Query payload with language name uses localized language label")
    func queryWithLanguageFallback() {
        let payload = EditorTabPayload(connectionId: UUID(), tabType: .query)
        let title = MainSplitViewController.resolveDefaultTitle(payload: payload, queryLanguageName: "PostgreSQL")
        #expect(title == String(format: String(localized: "%@ Query"), "PostgreSQL"))
    }

    @Test("Query payload with no language name falls back to SQL Query")
    func queryWithoutLanguageFallback() {
        let payload = EditorTabPayload(connectionId: UUID(), tabType: .query)
        let title = MainSplitViewController.resolveDefaultTitle(payload: payload, queryLanguageName: nil)
        #expect(title == String(localized: "SQL Query"))
    }
}

@Suite("MainSplitViewController.resolveDefaultSubtitle")
@MainActor
struct MainSplitViewControllerSubtitleTests {
    private let connection = DatabaseConnection(name: "MyConnection")

    private func tableTab(database: String, schema: String?) -> QueryTab {
        var tab = QueryTab(id: UUID(), title: "users", query: "SELECT 1", tabType: .table, tableName: "users")
        tab.tableContext.databaseName = database
        tab.tableContext.schemaName = schema
        return tab
    }

    @Test("Table tab with database and schema joins them with a middle dot")
    func tableTabWithSchemaAndDatabase() {
        let subtitle = MainSplitViewController.resolveDefaultSubtitle(
            tab: tableTab(database: "myapp", schema: "public"),
            connection: connection
        )
        #expect(subtitle == "myapp · public")
    }

    @Test("Table tab without schema shows the database alone")
    func tableTabWithDatabaseNoSchema() {
        let subtitle = MainSplitViewController.resolveDefaultSubtitle(
            tab: tableTab(database: "myapp", schema: nil),
            connection: connection
        )
        #expect(subtitle == "myapp")
    }

    @Test("Table tab with an empty schema shows the database alone")
    func tableTabWithEmptySchema() {
        let subtitle = MainSplitViewController.resolveDefaultSubtitle(
            tab: tableTab(database: "myapp", schema: ""),
            connection: connection
        )
        #expect(subtitle == "myapp")
    }

    @Test("Table tab with no database falls back to the connection name")
    func tableTabWithEmptyDatabaseName() {
        let subtitle = MainSplitViewController.resolveDefaultSubtitle(
            tab: tableTab(database: "", schema: nil),
            connection: connection
        )
        #expect(subtitle == connection.name)
    }

    @Test("Table tab with no table name falls back to the connection name")
    func tableTabWithNilTableName() {
        var tab = QueryTab(id: UUID(), title: "x", query: "SELECT 1", tabType: .table)
        tab.tableContext.databaseName = "myapp"
        let subtitle = MainSplitViewController.resolveDefaultSubtitle(tab: tab, connection: connection)
        #expect(subtitle == connection.name)
    }

    @Test("Query tab never shows a table subtitle even with a resolved table name")
    func queryTabReturnsConnectionName() {
        let tab = QueryTab(id: UUID(), title: "q", query: "SELECT 1", tabType: .query, tableName: "users")
        let subtitle = MainSplitViewController.resolveDefaultSubtitle(tab: tab, connection: connection)
        #expect(subtitle == connection.name)
    }

    @Test("Nil tab falls back to the connection name")
    func nilTabReturnsConnectionName() {
        let subtitle = MainSplitViewController.resolveDefaultSubtitle(tab: nil, connection: connection)
        #expect(subtitle == connection.name)
    }

    @Test("Server dashboard tab falls back to the connection name")
    func serverDashboardTabReturnsConnectionName() {
        let tab = QueryTab(id: UUID(), title: "d", query: "", tabType: .serverDashboard)
        let subtitle = MainSplitViewController.resolveDefaultSubtitle(tab: tab, connection: connection)
        #expect(subtitle == connection.name)
    }

    @Test("ER diagram tab falls back to the connection name")
    func erDiagramTabReturnsConnectionName() {
        let tab = QueryTab(id: UUID(), title: "e", query: "", tabType: .erDiagram)
        let subtitle = MainSplitViewController.resolveDefaultSubtitle(tab: tab, connection: connection)
        #expect(subtitle == connection.name)
    }

    @Test("Table payload with database and schema joins them with a middle dot")
    func tablePayloadWithSchemaAndDatabase() {
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .table,
            tableName: "users",
            databaseName: "myapp",
            schemaName: "public"
        )
        let subtitle = MainSplitViewController.resolveDefaultSubtitle(payload: payload, connection: connection)
        #expect(subtitle == "myapp · public")
    }

    @Test("Table payload without schema shows the database alone")
    func tablePayloadWithDatabaseNoSchema() {
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .table,
            tableName: "users",
            databaseName: "myapp"
        )
        let subtitle = MainSplitViewController.resolveDefaultSubtitle(payload: payload, connection: connection)
        #expect(subtitle == "myapp")
    }

    @Test("Table payload with no database falls back to the connection name")
    func tablePayloadWithNilDatabase() {
        let payload = EditorTabPayload(connectionId: UUID(), tabType: .table, tableName: "users")
        let subtitle = MainSplitViewController.resolveDefaultSubtitle(payload: payload, connection: connection)
        #expect(subtitle == connection.name)
    }

    @Test("Query payload falls back to the connection name")
    func queryPayloadReturnsConnectionName() {
        let payload = EditorTabPayload(connectionId: UUID(), tabType: .query, tableName: "users")
        let subtitle = MainSplitViewController.resolveDefaultSubtitle(payload: payload, connection: connection)
        #expect(subtitle == connection.name)
    }
}

@Suite("QueryTab.fileDisplayTitle")
struct QueryTabFileDisplayTitleTests {
    @Test("Returns FileManager display name for the URL")
    func returnsFileManagerDisplayName() {
        let url = URL(fileURLWithPath: "/tmp/report.sql")
        let title = QueryTab.fileDisplayTitle(for: url)
        #expect(title == FileManager.default.displayName(atPath: url.path(percentEncoded: false)))
    }

    @Test("Strips directory components")
    func stripsDirectoryComponents() {
        let url = URL(fileURLWithPath: "/var/folders/xyz/queries/report.sql")
        let title = QueryTab.fileDisplayTitle(for: url)
        #expect(!title.contains("/"))
    }

    @Test("Non-empty result for a file URL")
    func nonEmptyResult() {
        let url = URL(fileURLWithPath: "/tmp/report.sql")
        let title = QueryTab.fileDisplayTitle(for: url)
        #expect(!title.isEmpty)
    }
}

@Suite("QueryTabManager.addTab with sourceFileURL")
@MainActor
struct QueryTabManagerAddTabSourceFileTests {
    @Test("Tab title uses the shared file display title helper")
    func tabTitleUsesSharedHelper() {
        let tabManager = QueryTabManager()
        let url = URL(fileURLWithPath: "/tmp/report.sql")
        tabManager.addTab(sourceFileURL: url)
        let tab = tabManager.tabs.first
        #expect(tab?.title == QueryTab.fileDisplayTitle(for: url))
    }

    @Test("Explicit title argument wins over sourceFileURL")
    func explicitTitleWinsOverSourceFileURL() {
        let tabManager = QueryTabManager()
        let url = URL(fileURLWithPath: "/tmp/report.sql")
        tabManager.addTab(title: "favorite-name", sourceFileURL: url)
        let tab = tabManager.tabs.first
        #expect(tab?.title == "favorite-name")
    }
}
