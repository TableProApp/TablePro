import Foundation
@testable import TablePro
import Testing

@Suite("WindowTitleResolver.resolveTitle from payload")
@MainActor
struct WindowTitleResolverPayloadTitleTests {
    @Test("Nil payload falls back to SQL Query")
    func nilPayloadFallsBackToSQLQuery() {
        let title = WindowTitleResolver.resolveTitle(payload: nil, databaseType: nil, queryLanguageName: nil)
        #expect(title == String(localized: "SQL Query"))
    }

    @Test("Server dashboard payload returns Server Dashboard")
    func serverDashboardLabel() {
        let payload = EditorTabPayload(connectionId: UUID(), tabType: .serverDashboard)
        let title = WindowTitleResolver.resolveTitle(
            payload: payload, databaseType: .postgresql, queryLanguageName: "PostgreSQL"
        )
        #expect(title == String(localized: "Server Dashboard"))
    }

    @Test("ER diagram payload returns ER Diagram")
    func erDiagramLabel() {
        let payload = EditorTabPayload(connectionId: UUID(), tabType: .erDiagram)
        let title = WindowTitleResolver.resolveTitle(
            payload: payload, databaseType: .postgresql, queryLanguageName: "PostgreSQL"
        )
        #expect(title == String(localized: "ER Diagram"))
    }

    @Test("Create table payload returns Create Table")
    func createTableLabel() {
        let payload = EditorTabPayload(connectionId: UUID(), tabType: .createTable)
        let title = WindowTitleResolver.resolveTitle(
            payload: payload, databaseType: .postgresql, queryLanguageName: "PostgreSQL"
        )
        #expect(title == String(localized: "Create Table"))
    }

    @Test("Explicit tabTitle wins for query payloads")
    func explicitTabTitleWins() {
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .query,
            tabTitle: "report"
        )
        let title = WindowTitleResolver.resolveTitle(
            payload: payload, databaseType: .postgresql, queryLanguageName: "PostgreSQL"
        )
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
        let title = WindowTitleResolver.resolveTitle(
            payload: payload, databaseType: .postgresql, queryLanguageName: "PostgreSQL"
        )
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
        let title = WindowTitleResolver.resolveTitle(
            payload: payload, databaseType: .postgresql, queryLanguageName: "PostgreSQL"
        )
        #expect(title == "Renamed")
    }

    @Test("Source file URL takes precedence over tableName on query payloads")
    func sourceFileURLPrecedesTableName() {
        let url = URL(fileURLWithPath: "/tmp/report.sql")
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .query,
            tableName: "users",
            sourceFileURL: url
        )
        let title = WindowTitleResolver.resolveTitle(
            payload: payload, databaseType: .postgresql, queryLanguageName: "PostgreSQL"
        )
        #expect(title == QueryTab.fileDisplayTitle(for: url))
    }

    @Test("Table payload with tableName returns the table name")
    func tableNameUsedForTablePayload() {
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .table,
            tableName: "users"
        )
        let title = WindowTitleResolver.resolveTitle(
            payload: payload, databaseType: .postgresql, queryLanguageName: "PostgreSQL"
        )
        #expect(title == "users")
    }

    @Test("Table payload without a database type still returns the table name")
    func tableNameUsedWithoutDatabaseType() {
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .table,
            tableName: "users"
        )
        let title = WindowTitleResolver.resolveTitle(payload: payload, databaseType: nil, queryLanguageName: nil)
        #expect(title == "users")
    }

    @Test("Query payload with language name uses localized language label")
    func queryWithLanguageFallback() {
        let payload = EditorTabPayload(connectionId: UUID(), tabType: .query)
        let title = WindowTitleResolver.resolveTitle(
            payload: payload, databaseType: .postgresql, queryLanguageName: "PostgreSQL"
        )
        #expect(title == String(format: String(localized: "%@ Query"), "PostgreSQL"))
    }

    @Test("Query payload with no language name falls back to SQL Query")
    func queryWithoutLanguageFallback() {
        let payload = EditorTabPayload(connectionId: UUID(), tabType: .query)
        let title = WindowTitleResolver.resolveTitle(payload: payload, databaseType: .postgresql, queryLanguageName: nil)
        #expect(title == String(localized: "SQL Query"))
    }

    @Test("Table payload with an empty tabTitle resolves the table name, never blank")
    func tablePayloadWithEmptyTabTitleResolvesTableName() {
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .table,
            tableName: "orders",
            schemaName: "public",
            tabTitle: ""
        )
        let title = WindowTitleResolver.resolveTitle(
            payload: payload, databaseType: .postgresql, queryLanguageName: "PostgreSQL"
        )
        #expect(title == "orders")
    }

    @Test("Table payload in a non-default schema resolves the qualified name")
    func tablePayloadNonDefaultSchemaQualifies() {
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .table,
            tableName: "audit_log_entries",
            schemaName: "auth",
            tabTitle: ""
        )
        let title = WindowTitleResolver.resolveTitle(
            payload: payload, databaseType: .postgresql, queryLanguageName: "PostgreSQL"
        )
        #expect(title == "auth.audit_log_entries")
    }

    @Test("Table payload recomputes the title even when a tabTitle is present")
    func tablePayloadRecomputesOverExplicitTitle() {
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .table,
            tableName: "orders",
            schemaName: "auth",
            tabTitle: "stale carried-over name"
        )
        let title = WindowTitleResolver.resolveTitle(
            payload: payload, databaseType: .postgresql, queryLanguageName: "PostgreSQL"
        )
        #expect(title == "auth.orders")
    }

    @Test("Table payload with a blank tableName falls back to the explicit title")
    func tablePayloadBlankTableNameFallsBackToExplicitTitle() {
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .table,
            tableName: "",
            tabTitle: "auth.users"
        )
        let title = WindowTitleResolver.resolveTitle(
            payload: payload, databaseType: .postgresql, queryLanguageName: "PostgreSQL"
        )
        #expect(title == "auth.users")
    }

    @Test("Empty tabTitle falls through to the file display name")
    func emptyTabTitleFallsThroughToFileName() {
        let url = URL(fileURLWithPath: "/tmp/report.sql")
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .query,
            sourceFileURL: url,
            tabTitle: ""
        )
        let title = WindowTitleResolver.resolveTitle(
            payload: payload, databaseType: .postgresql, queryLanguageName: "PostgreSQL"
        )
        #expect(title == QueryTab.fileDisplayTitle(for: url))
    }

    @Test("Whitespace-only tabTitle is treated as absent")
    func whitespaceTabTitleTreatedAsAbsent() {
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .query,
            tabTitle: "   "
        )
        let title = WindowTitleResolver.resolveTitle(
            payload: payload, databaseType: .postgresql, queryLanguageName: "PostgreSQL"
        )
        #expect(title == String(format: String(localized: "%@ Query"), "PostgreSQL"))
    }

    @Test("Empty tabTitle with no other signal resolves to the fallback, never blank")
    func emptyTabTitleNeverResolvesBlank() {
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .query,
            tabTitle: ""
        )
        let title = WindowTitleResolver.resolveTitle(payload: payload, databaseType: nil, queryLanguageName: nil)
        #expect(title == WindowTitleResolver.fallbackTitle)
        #expect(!title.isBlank)
    }
}

@Suite("WindowTitleResolver.resolveTitle from tab")
@MainActor
struct WindowTitleResolverTabTitleTests {
    private let connection = DatabaseConnection(name: "MyConnection", type: .postgresql)

    @Test("Table tab with an empty title resolves the table name, never blank")
    func tableTabWithEmptyTitleResolvesTableName() {
        var tab = QueryTab(id: UUID(), title: "", query: "SELECT 1", tabType: .table, tableName: "orders")
        tab.tableContext.schemaName = "public"
        let title = WindowTitleResolver.resolveTitle(tab: tab, connection: connection, queryLanguageName: "PostgreSQL")
        #expect(title == "orders")
    }

    @Test("Table tab in a non-default schema resolves the qualified name")
    func tableTabNonDefaultSchemaQualifies() {
        var tab = QueryTab(id: UUID(), title: "", query: "SELECT 1", tabType: .table, tableName: "audit_log_entries")
        tab.tableContext.schemaName = "auth"
        let title = WindowTitleResolver.resolveTitle(tab: tab, connection: connection, queryLanguageName: "PostgreSQL")
        #expect(title == "auth.audit_log_entries")
    }

    @Test("Query tab keeps its own title")
    func queryTabKeepsOwnTitle() {
        let tab = QueryTab(id: UUID(), title: "Query 2", query: "SELECT 1", tabType: .query)
        let title = WindowTitleResolver.resolveTitle(tab: tab, connection: connection, queryLanguageName: "PostgreSQL")
        #expect(title == "Query 2")
    }

    @Test("Nil tab resolves to the language label")
    func nilTabResolvesLanguageLabel() {
        let title = WindowTitleResolver.resolveTitle(tab: nil, connection: connection, queryLanguageName: "PostgreSQL")
        #expect(title == String(format: String(localized: "%@ Query"), "PostgreSQL"))
    }
}

@Suite("WindowTitleResolver.sanitizeTitle")
@MainActor
struct WindowTitleResolverSanitizeTests {
    @Test("Non-blank candidate passes through")
    func nonBlankCandidatePasses() {
        #expect(WindowTitleResolver.sanitizeTitle(previous: "old", candidate: "new") == "new")
    }

    @Test("Blank candidate keeps the previous title")
    func blankCandidateKeepsPrevious() {
        #expect(WindowTitleResolver.sanitizeTitle(previous: "users", candidate: "") == "users")
    }

    @Test("Whitespace-only candidate keeps the previous title")
    func whitespaceCandidateKeepsPrevious() {
        #expect(WindowTitleResolver.sanitizeTitle(previous: "users", candidate: "   ") == "users")
    }

    @Test("Blank candidate over a blank previous returns the fallback")
    func blankOverBlankReturnsFallback() {
        #expect(WindowTitleResolver.sanitizeTitle(previous: "", candidate: "") == WindowTitleResolver.fallbackTitle)
    }
}

@Suite("WindowTitleResolver.resolveSubtitle from tab")
@MainActor
struct WindowTitleResolverTabSubtitleTests {
    private let connection = DatabaseConnection(name: "MyConnection")

    private func tableTab(database: String, schema: String?) -> QueryTab {
        var tab = QueryTab(id: UUID(), title: "users", query: "SELECT 1", tabType: .table, tableName: "users")
        tab.tableContext.databaseName = database
        tab.tableContext.schemaName = schema
        return tab
    }

    @Test("Table tab with database and schema joins them with a middle dot")
    func tableTabWithSchemaAndDatabase() {
        let subtitle = WindowTitleResolver.resolveSubtitle(
            tab: tableTab(database: "myapp", schema: "public"),
            connection: connection
        )
        #expect(subtitle == "myapp · public")
    }

    @Test("Table tab without schema shows the database alone")
    func tableTabWithDatabaseNoSchema() {
        let subtitle = WindowTitleResolver.resolveSubtitle(
            tab: tableTab(database: "myapp", schema: nil),
            connection: connection
        )
        #expect(subtitle == "myapp")
    }

    @Test("Table tab with an empty schema shows the database alone")
    func tableTabWithEmptySchema() {
        let subtitle = WindowTitleResolver.resolveSubtitle(
            tab: tableTab(database: "myapp", schema: ""),
            connection: connection
        )
        #expect(subtitle == "myapp")
    }

    @Test("Table tab with no database falls back to the connection name")
    func tableTabWithEmptyDatabaseName() {
        let subtitle = WindowTitleResolver.resolveSubtitle(
            tab: tableTab(database: "", schema: nil),
            connection: connection
        )
        #expect(subtitle == connection.name)
    }

    @Test("Table tab with no table name falls back to the connection name")
    func tableTabWithNilTableName() {
        var tab = QueryTab(id: UUID(), title: "x", query: "SELECT 1", tabType: .table)
        tab.tableContext.databaseName = "myapp"
        let subtitle = WindowTitleResolver.resolveSubtitle(tab: tab, connection: connection)
        #expect(subtitle == connection.name)
    }

    @Test("Query tab never shows a table subtitle even with a resolved table name")
    func queryTabReturnsConnectionName() {
        let tab = QueryTab(id: UUID(), title: "q", query: "SELECT 1", tabType: .query, tableName: "users")
        let subtitle = WindowTitleResolver.resolveSubtitle(tab: tab, connection: connection)
        #expect(subtitle == connection.name)
    }

    @Test("Nil tab falls back to the connection name")
    func nilTabReturnsConnectionName() {
        let subtitle = WindowTitleResolver.resolveSubtitle(tab: nil, connection: connection)
        #expect(subtitle == connection.name)
    }

    @Test("Server dashboard tab falls back to the connection name")
    func serverDashboardTabReturnsConnectionName() {
        let tab = QueryTab(id: UUID(), title: "d", query: "", tabType: .serverDashboard)
        let subtitle = WindowTitleResolver.resolveSubtitle(tab: tab, connection: connection)
        #expect(subtitle == connection.name)
    }

    @Test("ER diagram tab falls back to the connection name")
    func erDiagramTabReturnsConnectionName() {
        let tab = QueryTab(id: UUID(), title: "e", query: "", tabType: .erDiagram)
        let subtitle = WindowTitleResolver.resolveSubtitle(tab: tab, connection: connection)
        #expect(subtitle == connection.name)
    }
}

@Suite("WindowTitleResolver.resolveSubtitle from payload")
@MainActor
struct WindowTitleResolverPayloadSubtitleTests {
    private let connection = DatabaseConnection(name: "MyConnection")

    @Test("Table payload with database and schema joins them with a middle dot")
    func tablePayloadWithSchemaAndDatabase() {
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .table,
            tableName: "users",
            databaseName: "myapp",
            schemaName: "public"
        )
        let subtitle = WindowTitleResolver.resolveSubtitle(payload: payload, connection: connection)
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
        let subtitle = WindowTitleResolver.resolveSubtitle(payload: payload, connection: connection)
        #expect(subtitle == "myapp")
    }

    @Test("Table payload with no database falls back to the connection name")
    func tablePayloadWithNilDatabase() {
        let payload = EditorTabPayload(connectionId: UUID(), tabType: .table, tableName: "users")
        let subtitle = WindowTitleResolver.resolveSubtitle(payload: payload, connection: connection)
        #expect(subtitle == connection.name)
    }

    @Test("Query payload falls back to the connection name")
    func queryPayloadReturnsConnectionName() {
        let payload = EditorTabPayload(connectionId: UUID(), tabType: .query, tableName: "users")
        let subtitle = WindowTitleResolver.resolveSubtitle(payload: payload, connection: connection)
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
