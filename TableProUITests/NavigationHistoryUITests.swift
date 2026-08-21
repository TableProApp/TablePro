import AppKit
import XCTest

/// Issue #2316. Following a reference used to be one-way: the view you came from was gone, with no
/// control anywhere that brought it back. Back is driven here through the menu bar rather than the
/// toolbar button, because that is the path the key equivalent takes too.
final class NavigationHistoryUITests: UITestCase {
    func testBackReturnsToTheTableTheTabWasRetargetedAwayFrom() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        click(row("Album", in: window))
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { title(of: window).contains("Album") },
            "The tab must be showing Album before anything retargets it. Title: \(title(of: window))"
        )

        click(row("Artist", in: window))
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { title(of: window).contains("Artist") },
            "Clicking a second table must retarget the preview tab. Title: \(title(of: window))"
        )

        try clickViewMenuItem("Back", in: app)

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { title(of: window).contains("Album") },
            "Back must put the table the tab was retargeted away from back. Title: \(title(of: window))"
        )
    }

    func testBackIsDisabledUntilSomethingHasBeenNavigatedAwayFrom() throws {
        let app = try launchWithSampleDatabase()
        _ = try readyWindow(of: app)

        let back = try viewMenuItem("Back", in: app)
        XCTAssertFalse(
            back.isEnabled,
            "Back must be offered and disabled, not hidden, while the tab has no history"
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    func testForwardReturnsToTheTableBackSteppedAwayFrom() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        click(row("Album", in: window))
        _ = waitForPredicate(timeout: 20) { title(of: window).contains("Album") }
        click(row("Artist", in: window))
        _ = waitForPredicate(timeout: 20) { title(of: window).contains("Artist") }

        try clickViewMenuItem("Back", in: app)
        XCTAssertTrue(waitForPredicate(timeout: 20) { title(of: window).contains("Album") })

        try clickViewMenuItem("Forward", in: app)

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { title(of: window).contains("Artist") },
            "Forward must return to the table Back stepped away from. Title: \(title(of: window))"
        )
    }

    // MARK: - Helpers

    private func readyWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 30))
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.outlines.firstMatch.outlineRows.count > 1 },
            "The object browser must list the sample database's tables"
        )
        return window
    }

    /// The tree draws its rows as hosted cells, so the name arrives as the static text's `value`
    /// rather than as a label, and the rows themselves report as disabled. Matching on `value` is
    /// what finds them; clicking through a coordinate is what reaches them.
    private func row(_ name: String, in window: XCUIElement) -> XCUIElement {
        let match = window.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", "Table: \(name)"))
            .firstMatch
        XCTAssertTrue(match.waitToExist(timeout: 20), "The object browser must list \(name)")
        return match
    }

    private func click(_ element: XCUIElement) {
        clickAtCenter(element)
        Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval)
    }

    private func title(of window: XCUIElement) -> String {
        window.title
    }

    private func viewMenuItem(_ name: String, in app: XCUIApplication) throws -> XCUIElement {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))
        let viewMenu = menuBar.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitToExist(timeout: 10))
        viewMenu.click()
        let item = viewMenu.menuItems[name]
        XCTAssertTrue(item.waitToExist(timeout: 10), "View must offer \(name)")
        return item
    }

    private func clickViewMenuItem(_ name: String, in app: XCUIApplication) throws {
        let item = try viewMenuItem(name, in: app)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { item.isEnabled },
            "View > \(name) must be enabled once the tab has a history"
        )
        item.click()
    }
}
