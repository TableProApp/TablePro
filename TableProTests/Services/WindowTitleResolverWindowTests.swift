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

@Suite("WindowTitleResolver.resolveWindow")
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
        .unavailable(.pluginMissing(ConnectionFailureInfo(message: "missing"))),
    ]

    @Test("A window that is not showing content is named after its connection, never a tab")
    func nonContentPanesUseTheConnectionName() {
        let connection = Self.connection()

        for pane in Self.nonContentPanes {
            let resolved = WindowTitleResolver.resolveWindow(
                pane: pane,
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
            connection: connection,
            tab: tab,
            hasTabs: true,
            queryLanguageName: "PostgreSQL"
        )

        #expect(resolved.title == "Weekly Query")
    }
}
