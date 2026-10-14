import XCTest

// ConnectionSwitcherSectionsTests covers the grouping; this covers reaching a saved connection from the window.
final class GroupedConnectionSwitcherUITests: UITestCase {
    private let savedName = "Ledger"
    private let savedTable = "ledger_entry"

    func testTheSwitcherReachesASavedConnectionInTheSameWindow() throws {
        let launch = try launchWithFixture([
            ConnectionSeed(),
            ConnectionSeed(
                name: savedName,
                databaseSQL: "CREATE TABLE \(savedTable) (id INTEGER PRIMARY KEY, amount INTEGER NOT NULL);",
                tabs: [],
                isOpen: false
            ),
        ])
        let app = launch.app
        XCTAssertEqual(mainWindowCount(in: app), 1)

        app.typeShortcut(.switchConnection)
        let field = connectionSearchField(in: app)
        XCTAssertTrue(field.waitToExist(timeout: 15), "Switch Connection must open the switcher")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { !field.exists },
            "Escape on an empty filter must dismiss the switcher"
        )

        // A stuck isPresented binding makes the second press toggle the popover off instead of showing it.
        app.typeShortcut(.switchConnection)
        XCTAssertTrue(field.waitToExist(timeout: 10), "The switcher must reopen after an Escape dismissal")

        app.typeText(savedName)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !field.exists },
            "Activating a connection must dismiss the switcher"
        )

        XCTAssertTrue(
            objectBrowserRow(savedTable, in: launch.window).waitToExist(timeout: 30),
            "The window the switcher was opened from must show the saved connection"
        )
        XCTAssertEqual(mainWindowCount(in: app), 1, "Switching connection must not open a window")
    }

    // Matched on the placeholder: every NativeSearchField publishes the same default identifier,
    // and the object browser's filter field is always on screen.
    private func connectionSearchField(in app: XCUIApplication) -> XCUIElement {
        app.searchFields.matching(
            NSPredicate(format: "placeholderValue BEGINSWITH[c] %@", "Search connections")
        ).firstMatch
    }

    private func mainWindowCount(in app: XCUIApplication) -> Int {
        app.children(matching: .window).matching(identifier: "main").count
    }
}
