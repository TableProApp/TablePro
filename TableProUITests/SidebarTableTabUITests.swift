import XCTest

/// Issue #2235. Clicking a table opens it in a preview tab that the next click reuses, so browsing
/// several tables used to leave them all fighting over one tab. Double-clicking one keeps it.
final class SidebarTableTabUITests: UITestCase {
    func testDoubleClickingATableKeepsItsTabSoTheNextTableGetsItsOwn() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        /// Establishes the state the issue describes: a preview tab showing Album. Whether the
        /// sample database left a tab of its own open does not matter, because the assertion is
        /// about the change in the count rather than its value.
        click(row("Album", in: window))
        let beforeKeeping = tabCount(in: window)

        doubleClick(row("Album", in: window))
        click(row("Artist", in: window))

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { tabCount(in: window) > beforeKeeping },
            """
            A double-clicked table keeps its tab, so clicking a second table must open a second tab \
            rather than replacing the first. Tabs before: \(beforeKeeping), after: \
            \(tabCount(in: window)).
            """
        )
    }

    func testClickingASecondTableStillReusesThePreviewTab() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        click(row("Album", in: window))
        let beforeSecondClick = tabCount(in: window)

        click(row("Artist", in: window))

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { tabCount(in: window) == beforeSecondClick },
            """
            A single click still opens into the preview tab, which the next click reuses. \
            Tabs before: \(beforeSecondClick), after: \(tabCount(in: window)).
            """
        )
    }

    private func readyWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30))
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.outlines.firstMatch.outlineRows.count > 1 },
            "The object browser must list the sample database's tables"
        )
        return window
    }

    /// The tree draws its rows as hosted cells, so the name arrives as the static text's `value`
    /// rather than as a label or an identifier, and AppKit reports the rows themselves as disabled.
    /// Matching on `value` is what finds them; clicking through a coordinate is what reaches them.
    private func row(_ name: String, in window: XCUIElement) -> XCUIElement {
        let match = window.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", "Table: \(name)"))
            .firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 20), "The object browser must list \(name)")
        return match
    }

    private func click(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        _ = waitForPredicate(timeout: 3) { false }
    }

    private func doubleClick(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        _ = waitForPredicate(timeout: 3) { false }
    }

    /// The strip is drawn only once a connection holds more than one tab, so one tab reads as zero
    /// here. The tests compare counts rather than read a total, which holds either way.
    private func tabCount(in window: XCUIElement) -> Int {
        window.descendants(matching: .any).matching(identifier: "editor-tab").count
    }
}
