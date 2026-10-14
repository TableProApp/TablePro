import XCTest

// Once one connection is hosted by two windows, the tab must not be lost from both, and the shared
// session must not go down with whichever window closes first.
final class EditorTabDetachUITests: UITestCase {
    func testADetachedTabWorksInItsOwnWindowAndTheOriginalKeepsWorking() throws {
        let tables = ["album", "artist", "genre"]
        let launch = try launchWithFixture([ConnectionSeed(tabs: tables.map { SeededTab.table($0) })])
        let app = launch.app
        let window = launch.window

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.editorTabTitles(in: window) == tables },
            "The strip must restore a tab per table, got \(editorTabTitles(in: window))"
        )
        let moved = editorTab(titled: "genre", in: window)
        XCTAssertTrue(waitUntilHittable(moved, timeout: 20), "The tab to move must be on screen")
        moved.rightClick()
        let command = contextMenuItem("Move Tab to New Window", in: app)
        XCTAssertTrue(command.waitToExist(timeout: 5), "The tab's menu must offer Move Tab to New Window")
        command.click()

        // `mainWindow(in:)` re-resolves to either window once there are two, so each is found by what it holds.
        let windows = app.children(matching: .window)
        XCTAssertTrue(waitForPredicate(timeout: 20) { windows.count == 2 }, "The move must open a second window")
        // A window holding one tab hides its strip, so the detached one is known by its title.
        let detached = windows.matching(NSPredicate(format: "title CONTAINS %@", "genre")).firstMatch
        XCTAssertTrue(detached.waitToExist(timeout: 20), "A window must be titled for the moved tab")
        XCTAssertTrue(
            waitForPredicate(timeout: 20) {
                windows.allElementsBoundByIndex.contains { self.editorTabTitles(in: $0) == ["album", "artist"] }
            },
            "The original window must keep the tabs that stayed behind"
        )

        detached.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { windows.count == 1 },
            "Closing the detached window must close it rather than empty it"
        )

        let original = mainWindow(in: app)
        XCTAssertEqual(editorTabTitles(in: original), ["album", "artist"], "The remaining window keeps its tabs")
        selectEditorTab(titled: "artist", in: original)
        XCTAssertTrue(
            gridCell(showing: "Ada", in: dataGrid(in: original)).waitToExist(timeout: 20),
            "The connection must still load a table after the other window closed"
        )
    }
}
