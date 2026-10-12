import XCTest

/// #2927: the completion list over a filter field preselected its first row the moment it opened,
/// so `Return` accepted a suggestion the user never asked for and the filter went unapplied until
/// they pressed `Escape` first.
///
/// The list itself is not asserted on. Its rows are a SwiftUI popover the runner does not resolve
/// reliably, which is the same reason `EditorAutocompleteFocusUITests` asserts on committed text.
/// **Clear** is the observable proof instead: it is enabled only once a filter has been applied.
final class FilterBarReturnUITests: UITestCase {
    func testReturnAppliesAFilterWhoseLastTokenStillMatchesSuggestions() throws {
        let app = try launchWithSampleDatabase()
        let window = try openAlbum(in: app)

        openFilterBar(in: app)
        app.typeText("ArtistId IS NOT NULL")
        settleCompletion()
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { window.buttons["Clear"].isEnabled },
            "Return must apply the filter while the completion list is open on the NULL keyword"
        )
    }

    func testReturnAppliesAFilterThatEndsOnAClosingQuote() throws {
        let app = try launchWithSampleDatabase()
        let window = try openAlbum(in: app)

        openFilterBar(in: app)
        app.typeText("Title='Let There Be Rock'")
        settleCompletion()
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { window.buttons["Clear"].isEnabled },
            "Return must apply a filter that ends on a closing quote, with no Escape first"
        )
    }

    private func openAlbum(in app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 30))

        let row = window.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", "Table: Album"))
            .firstMatch
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list Album")
        clickAtCenter(row)
        return window
    }

    /// The panel adds a row and focuses it in `onAppear`, and a new row starts in raw SQL, so the
    /// text goes straight to the field the popup hangs off.
    private func openFilterBar(in app: XCUIApplication) {
        app.typeKey("f", modifierFlags: [.command, .shift])
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
    }

    /// The request is debounced 50ms and then makes a schema round trip, so the list is not up on
    /// the keystroke that asked for it.
    private func settleCompletion() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.5))
    }
}
