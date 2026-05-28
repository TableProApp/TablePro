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
