import XCTest

/// Escape has to dismiss the switcher surfaces, not just the Open Quickly panel, and it has to do
/// it through a real key press: the unit tests call the delegate hook directly, which is below the
/// menu-equivalent and responder-chain stages where a dismissal actually gets lost.
final class SwitcherEscapeUITests: UITestCase {
    func testEscapeDismissesTheConnectionSwitcher() throws {
        let app = try launchWithSampleDatabase()
        try waitForGrid(in: app)

        app.typeKey("c", modifierFlags: [.command, .control])
        let field = connectionSearchField(in: app)
        XCTAssertTrue(field.waitToExist(timeout: 15))

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            field.waitForNonExistence(timeout: 5),
            "Escape on an empty filter must dismiss the connection switcher"
        )
    }

    /// Reopening is the half a stuck `isPresented` binding breaks: AppKit can close the popover
    /// window while SwiftUI still believes it is showing, and the toolbar command then toggles the
    /// binding off instead of presenting again.
    func testTheConnectionSwitcherReopensAfterEscape() throws {
        let app = try launchWithSampleDatabase()
        try waitForGrid(in: app)

        app.typeKey("c", modifierFlags: [.command, .control])
        let field = connectionSearchField(in: app)
        XCTAssertTrue(field.waitToExist(timeout: 15))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))

        app.typeKey("c", modifierFlags: [.command, .control])
        XCTAssertTrue(
            field.waitToExist(timeout: 10),
            "The switcher must reopen after an Escape dismissal"
        )
    }

    private func waitForGrid(in app: XCUIApplication) throws {
        XCTAssertTrue(
            app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
                .waitToExist(timeout: 30)
        )
        app.activate()
    }

    /// Keyed on the placeholder because every `NativeSearchField` publishes the same default
    /// identifier, so an identifier match cannot tell the switcher popovers apart.
    private func connectionSearchField(in app: XCUIApplication) -> XCUIElement {
        app.searchFields.matching(
            NSPredicate(format: "placeholderValue BEGINSWITH[c] %@", "Search connections")
        ).firstMatch
    }
}
