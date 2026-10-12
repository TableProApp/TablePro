import XCTest

/// #3006: a filter that is in the bar but not running had nowhere to be saved, so **Clear** deleted
/// the table's rows along with the query, and reopening the table brought back an empty bar.
///
/// **Clear** is the observable state on both counts: it exists only inside the filter bar, so its
/// presence proves the bar came back with rows in it, and it is enabled only while a filter is
/// applied, so its being dimmed proves nothing is running.
final class FilterPersistenceUITests: UITestCase {
    func testClearedFilterRowsComeBackWhenTheTableIsReopened() throws {
        let app = try launchWithSampleDatabase()
        let window = try openTable("Album", in: app)

        app.typeKey("f", modifierFlags: [.command, .shift])
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
        app.typeText("ArtistId IS NOT NULL")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.5))
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { window.buttons["Clear"].isEnabled },
            "The filter must apply before the rest of the test means anything"
        )

        clickAtCenter(window.buttons["Clear"])
        XCTAssertTrue(
            waitForPredicate(timeout: 10) {
                window.buttons["Clear"].exists && !window.buttons["Clear"].isEnabled
            },
            "Clear must stop filtering and leave the rows in the bar"
        )

        _ = try openTable("Artist", in: app)
        _ = try openTable("Album", in: app)

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { window.buttons["Clear"].exists },
            "Reopening the table must bring the cleared filter rows back in the bar"
        )
        XCTAssertFalse(
            window.buttons["Clear"].isEnabled,
            "The restored rows must not be running"
        )
    }

    private func openTable(_ tableName: String, in app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 30))

        let row = window.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", "Table: \(tableName)"))
            .firstMatch
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list \(tableName)")
        clickAtCenter(row)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.5))
        return window
    }
}
