import XCTest

final class ReopenClosedTabUITests: UITestCase {
    private static let tables = ["album", "artist", "genre"]

    // Nothing is clicked before Cmd+W: the window's first responder used to be the connection rail,
    // which answers Close itself, so the keystroke closed a connection instead of a tab. Reopen then
    // took the tab out of its history and opened nothing while the window still had other tabs.
    func testCommandWClosesATabAndShiftCommandTBringsItBack() throws {
        let tabs = Self.tables.map { SeededTab.table($0) }
        let launch = try launchWithFixture([
            ConnectionSeed(name: "Fixture A", tabs: tabs),
            ConnectionSeed(name: "Fixture B", tabs: tabs),
        ])
        let app = launch.app
        let window = launch.window

        let rail = window.tables.matching(identifier: "workspace-rail").firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { rail.exists && rail.tableRows.count == 2 },
            "Both restored connections must be listed in the rail"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { self.editorTabTitles(in: window) == Self.tables },
            "The connection on screen must restore its tabs, got \(editorTabTitles(in: window))"
        )
        let closed = try XCTUnwrap(selectedEditorTabTitle(in: window), "A restored tab must be selected")

        app.typeShortcut(.closeTab)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.editorTabTitles(in: window) == Self.tables.filter { $0 != closed } },
            "Cmd+W must close the selected tab, got \(editorTabTitles(in: window))"
        )
        XCTAssertEqual(rail.tableRows.count, 2, "Neither connection may close with the tab")

        app.typeShortcut(.reopenClosedTab)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.selectedEditorTabTitle(in: window) == closed },
            "Cmd+Shift+T must bring \(closed) back selected, got \(editorTabTitles(in: window))"
        )
    }
}
