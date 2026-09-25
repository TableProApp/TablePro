//
//  WindowTitleResolverWindowTests.swift
//  TableProTests
//
//  The window's name used to be decided by whoever wrote to it last. A connecting window was
//  called "SQL Query" after a tab it did not have, a window that lost its session kept the name
//  of the table it had stopped showing, and two callers each picked the connection name without
//  knowing the other had, which is how a titlebar came to read "TablePro - TablePro".
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct WindowTitleResolverWindowTests {
    private static func connection(name: String = "Prod DB") -> DatabaseConnection {
        DatabaseConnection(
            name: name,
            host: "db.internal",
            port: 5_432,
            database: "shop",
            username: "postgres",
            type: .postgresql
        )
    }

    private static let nonContentPanes: [ConnectionWindowPane] = [
        .connecting,
        .empty,
        .unavailable(.notConnected),
        .unavailable(.cancelled),
        .unavailable(.disconnected(nil)),
        .unavailable(.failed(ConnectionFailureInfo(message: "refused"))),
        .unavailable(.actionRequired(ConnectionFailureInfo(message: "missing"), .installPlugin)),
    ]

    @Test("A window that is not showing content is named after its connection, never a tab")
    func nonContentPanesUseTheConnectionName() {
        let connection = Self.connection()

        for pane in Self.nonContentPanes {
            let resolved = WindowTitleResolver.resolveWindow(
                pane: pane,
                contentMode: .browse,
                agentSessionTitle: nil,
                connection: connection,
                tab: nil,
                hasTabs: false,
                queryLanguageName: "PostgreSQL"
            )

            #expect(resolved.title == "Prod DB")
            #expect(resolved.subtitle.isEmpty)
            #expect(resolved.title != WindowTitleResolver.fallbackTitle)
        }
    }

    /// The regression that started this: a connecting window carries tabs restored from disk,
    /// and naming it after one of them announced a table nobody could see yet.
    @Test("Restored tabs do not leak into the name of a window that is still connecting")
    func connectingIgnoresRestoredTabs() {
        let resolved = WindowTitleResolver.resolveWindow(
            pane: .connecting,
            contentMode: .browse,
            agentSessionTitle: nil,
            connection: Self.connection(),
            tab: nil,
            hasTabs: true,
            queryLanguageName: "PostgreSQL"
        )

        #expect(resolved.title == "Prod DB")
        #expect(resolved.subtitle.isEmpty)
    }

    @Test("A content window with no tabs is named after its connection and carries no subtitle")
    func emptyContentWindowHasNoSubtitle() {
        let resolved = WindowTitleResolver.resolveWindow(
            pane: .content,
            contentMode: .browse,
            agentSessionTitle: nil,
            connection: Self.connection(),
            tab: nil,
            hasTabs: false,
            queryLanguageName: "PostgreSQL"
        )

        #expect(resolved.title == "Prod DB")
        #expect(resolved.subtitle.isEmpty)
    }

    @Test("The subtitle never repeats the title")
    func subtitleNeverRepeatsTitle() {
        let connection = Self.connection(name: "shop")

        for pane in Self.nonContentPanes + [.content] {
            let resolved = WindowTitleResolver.resolveWindow(
                pane: pane,
                contentMode: .browse,
                agentSessionTitle: nil,
                connection: connection,
                tab: nil,
                hasTabs: false,
                queryLanguageName: "PostgreSQL"
            )

            #expect(resolved.subtitle != resolved.title)
        }
    }

    @Test("A connection with no name still produces a usable window name")
    func blankConnectionNameFallsBack() {
        let resolved = WindowTitleResolver.resolveWindow(
            pane: .connecting,
            contentMode: .browse,
            agentSessionTitle: nil,
            connection: Self.connection(name: "   "),
            tab: nil,
            hasTabs: false,
            queryLanguageName: nil
        )

        #expect(!resolved.title.isBlank)
        #expect(resolved.title == WindowTitleResolver.fallbackTitle)
    }

    @Test("A window with no connection at all still produces a usable name")
    func missingConnectionFallsBack() {
        let resolved = WindowTitleResolver.resolveWindow(
            pane: .empty,
            contentMode: .browse,
            agentSessionTitle: nil,
            connection: nil,
            tab: nil,
            hasTabs: false,
            queryLanguageName: nil
        )

        #expect(resolved.title == WindowTitleResolver.fallbackTitle)
        #expect(resolved.subtitle.isEmpty)
    }

    /// A user is free to name a tab "Weekly Query". The old placeholder detector matched any
    /// title ending in " Query" and overwrote it, and matched the English rendering of a
    /// localized format string, so it did nothing at all in a translated build.
    @Test("A tab a user named themselves survives, whatever it ends with")
    func userNamedTabSurvives() {
        let connection = Self.connection()
        var tab = QueryTab(id: UUID(), title: "Weekly Query", query: "SELECT 1", tabType: .query)
        tab.tableContext.databaseName = "shop"

        let resolved = WindowTitleResolver.resolveWindow(
            pane: .content,
            contentMode: .browse,
            agentSessionTitle: nil,
            connection: connection,
            tab: tab,
            hasTabs: true,
            queryLanguageName: "PostgreSQL"
        )

        #expect(resolved.title == "Weekly Query")
    }

    // MARK: - Agent mode

    /// Agent mode puts the conversation in the detail column and the editor tabs behind it. The
    /// titlebar went on naming whichever tab was selected when the mode came on.
    @Test("Agent mode names the session, never the tab behind the conversation")
    func agentModeNamesTheSession() {
        let resolved = WindowTitleResolver.resolveWindow(
            pane: .content,
            contentMode: .agent,
            agentSessionTitle: "Orders shipped late",
            connection: Self.connection(),
            tab: Self.tableTab(),
            hasTabs: true,
            queryLanguageName: "PostgreSQL"
        )

        #expect(resolved.title == "Orders shipped late")
        #expect(resolved.subtitle.isEmpty)
    }

    /// The conversation is drawn while the connection is still coming up, so it is what the window
    /// is showing then too.
    @Test("Agent mode names the session over a connection that is still connecting")
    func agentModeNamesTheSessionWhileConnecting() {
        let resolved = WindowTitleResolver.resolveWindow(
            pane: .connecting,
            contentMode: .agent,
            agentSessionTitle: "Orders shipped late",
            connection: Self.connection(),
            tab: nil,
            hasTabs: true,
            queryLanguageName: "PostgreSQL"
        )

        #expect(resolved.title == "Orders shipped late")
    }

    /// A session has no name until its first question or reply gives it one, and a blank title is
    /// never allowed to reach the window.
    @Test("A session with no name yet, or no session at all, names the mode", arguments: [nil, "", "   "])
    func unnamedSessionNamesTheMode(sessionTitle: String?) {
        let resolved = WindowTitleResolver.resolveWindow(
            pane: .content,
            contentMode: .agent,
            agentSessionTitle: sessionTitle,
            connection: Self.connection(),
            tab: Self.tableTab(),
            hasTabs: true,
            queryLanguageName: "PostgreSQL"
        )

        #expect(resolved.title == ConnectionWorkspaceContentMode.agent.localizedTitle)
        #expect(!resolved.title.isBlank)
        #expect(resolved.subtitle.isEmpty)
    }

    /// The unavailable screen is what the detail column shows then, whichever mode the window is in,
    /// and it is the connection that is not there.
    @Test("Agent mode over a connection that cannot be reached names the connection")
    func agentModeOverAnUnreachableConnectionNamesIt() {
        let panes: [ConnectionWindowPane] = [
            .empty,
            .unavailable(.notConnected),
            .unavailable(.disconnected(nil)),
            .unavailable(.failed(ConnectionFailureInfo(message: "refused"))),
        ]
        for pane in panes {
            let resolved = WindowTitleResolver.resolveWindow(
                pane: pane,
                contentMode: .agent,
                agentSessionTitle: "Orders shipped late",
                connection: Self.connection(),
                tab: nil,
                hasTabs: false,
                queryLanguageName: "PostgreSQL"
            )

            #expect(resolved.title == "Prod DB", "\(pane)")
        }
    }

    @Test("A session's name is ignored while browsing")
    func browsingIgnoresTheSession() {
        let resolved = WindowTitleResolver.resolveWindow(
            pane: .content,
            contentMode: .browse,
            agentSessionTitle: "Orders shipped late",
            connection: Self.connection(),
            tab: Self.tableTab(),
            hasTabs: true,
            queryLanguageName: "PostgreSQL"
        )

        #expect(resolved.title == "orders")
    }

    // MARK: - Proxy icon

    /// The proxy icon is decided with the title, so only the tab the window names can set it.
    @Test("The file behind the named tab is the window's proxy icon")
    func fileTabSetsTheProxyIcon() {
        let resolved = WindowTitleResolver.resolveWindow(
            pane: .content,
            contentMode: .browse,
            agentSessionTitle: nil,
            connection: Self.connection(),
            tab: Self.fileTab(),
            hasTabs: true,
            queryLanguageName: "PostgreSQL"
        )

        #expect(resolved.representedURL == Self.fileURL)
    }

    /// A conversation is not a file. The browse content used to set the icon straight on the
    /// window, so the tab behind the conversation kept its file's icon beside the session's name.
    @Test("Agent mode shows no proxy icon, whatever file the tab behind it came from")
    func agentModeHasNoProxyIcon() {
        let resolved = WindowTitleResolver.resolveWindow(
            pane: .content,
            contentMode: .agent,
            agentSessionTitle: "Orders shipped late",
            connection: Self.connection(),
            tab: Self.fileTab(),
            hasTabs: true,
            queryLanguageName: "PostgreSQL"
        )

        #expect(resolved.representedURL == nil)
    }

    /// A window that is not showing content is not showing the tab's file either.
    @Test("A window that is not showing content has no proxy icon")
    func nonContentPanesHaveNoProxyIcon() {
        for pane in Self.nonContentPanes {
            let resolved = WindowTitleResolver.resolveWindow(
                pane: pane,
                contentMode: .browse,
                agentSessionTitle: nil,
                connection: Self.connection(),
                tab: Self.fileTab(),
                hasTabs: true,
                queryLanguageName: "PostgreSQL"
            )

            #expect(resolved.representedURL == nil, "\(pane)")
        }
    }

    private static let fileURL = URL(fileURLWithPath: "/tmp/orders.sql")

    private static func fileTab() -> QueryTab {
        var tab = QueryTab(id: UUID(), title: "orders.sql", query: "SELECT 1", tabType: .query)
        tab.content.sourceFileURL = fileURL
        return tab
    }

    private static func tableTab() -> QueryTab {
        var tab = QueryTab(id: UUID(), title: "orders", query: "SELECT * FROM orders", tabType: .table)
        tab.tableContext.tableName = "orders"
        return tab
    }
}
