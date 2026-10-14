import XCTest

// Control-Tab walks the window's tabs in the order they were used, not the order the strip draws them (#2524).
final class RecentTabSwitchingUITests: UITestCase {
    // Using track and then artist makes track the last tab before artist, and neither of artist's neighbours.
    // Holding Control is covered by RecentTabSwitcherControllerTests.
    func testControlTabWalksTabsInTheOrderTheyWereUsed() throws {
        let tables = ["album", "artist", "genre", "track"]
        let launch = try launchWithFixture([ConnectionSeed(tabs: tables.map { SeededTab.table($0) })])
        let app = launch.app
        let window = launch.window

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.editorTabTitles(in: window) == tables },
            "The strip must restore a tab per table, got \(editorTabTitles(in: window))"
        )
        selectEditorTab(titled: "track", in: window)
        selectEditorTab(titled: "artist", in: window)

        app.typeShortcut(.recentTab)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.selectedEditorTabTitle(in: window) == "track" },
            "A tap must go back to track, the tab used before artist. Got \(selectedEditorTabTitle(in: window) ?? "none")"
        )

        app.typeShortcut(.recentTab)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.selectedEditorTabTitle(in: window) == "artist" },
            "A second tap must come back to artist. Got \(selectedEditorTabTitle(in: window) ?? "none")"
        )
    }
}
