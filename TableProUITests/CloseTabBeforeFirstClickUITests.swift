import XCTest

/// Command W closed the whole connection instead of the current tab in a window nobody had clicked
/// into yet: after a relaunch that restored the session, and on a connection opened fresh.
///
/// AppKit gave the window its first responder as it appeared, and the connections strip's list was
/// the only candidate, on screen or collapsed to zero width. The strip answers Close itself, so the
/// keystroke closed its entry. Clicking the editor or the grid moved the keyboard out of the strip,
/// which is why the bug only showed before the first click.
///
/// Nothing is clicked in either test, on purpose: the first click is what hid the bug.
final class CloseTabBeforeFirstClickUITests: UITestCase {
    func testCommandWBeforeAnyClickClosesTheTabAndKeepsTheConnection() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows["main"]
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The sample database opens on a table tab")

        app.typeKey("w", modifierFlags: .command)

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { !grid.exists },
            "Command W must close the table tab"
        )
        XCTAssertTrue(
            window.outlines.firstMatch.waitToExist(timeout: 5),
            "The connection must stay open on its empty state, not close with the tab"
        )
    }

    /// Two restored connections, so the strip is on screen by the time Command W is pressed, which
    /// is where anyone who reopens more than one connection lands.
    func testCommandWInARestoredSessionClosesATabAndKeepsBothConnections() throws {
        try seedSQLiteSession(
            connectionNames: ["Restored A", "Restored B"],
            databaseSQL: "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO items (name) VALUES ('one');",
            tabsEach: 3
        )
        let app = try launchApp()
        let window = app.windows["main"]
        let strip = window.tables.matching(identifier: "workspace-rail").firstMatch

        XCTAssertTrue(
            waitForPredicate(timeout: 60) { strip.exists && strip.tableRows.count == 2 },
            "Both restored connections must be listed in the strip"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { self.tabCount(in: window) == 3 },
            "The selected connection must restore its three tabs"
        )

        app.typeKey("w", modifierFlags: .command)

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.tabCount(in: window) == 2 },
            "Command W must close one tab. Tabs now: \(tabCount(in: window))"
        )
        XCTAssertEqual(strip.tableRows.count, 2, "Neither connection may close with the tab")
    }

    private func tabCount(in window: XCUIElement) -> Int {
        window.descendants(matching: .any).matching(identifier: "editor-tab").count
    }
}
