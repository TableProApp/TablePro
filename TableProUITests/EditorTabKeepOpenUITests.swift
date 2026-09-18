import AppKit
import XCTest

/// Issue #2436. A table already open in a preview tab could only be kept by closing it and
/// double-clicking it again in the sidebar. Double-clicking the tab itself now keeps it, the way
/// TablePlus, VS Code, DataGrip and Xcode all do.
final class EditorTabKeepOpenUITests: UITestCase {
    func testDoubleClickingAPreviewTabKeepsItSoTheNextTableGetsItsOwn() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        /// Two tables, so the strip is drawn at all: it stays hidden while a connection holds one
        /// tab. Album is kept first so Artist lands in the preview tab that this test promotes.
        doubleClick(row("Album", in: window))
        click(row("Artist", in: window))
        /// Counted only once the strip is up. Sampling before the wait reads zero on a strip that
        /// has not been drawn, and `> beforeKeeping` then passes without the feature running.
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.tab(named: "Artist", in: window).exists },
            "The strip must show the preview tab for Artist"
        )
        let beforeKeeping = tabCount(in: window)

        doubleClick(tab(named: "Artist", in: window))
        click(row("Customer", in: window))

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.tabCount(in: window) > beforeKeeping },
            """
            Double-clicking a preview tab keeps it, so opening a third table must add a tab rather \
            than take the kept one over. Tabs before: \(beforeKeeping), after: \
            \(tabCount(in: window)).
            """
        )
    }

    func testASingleClickOnAPreviewTabDoesNotKeepIt() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        doubleClick(row("Album", in: window))
        click(row("Artist", in: window))
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.tab(named: "Artist", in: window).exists },
            "The strip must show the preview tab for Artist"
        )
        let beforeSelecting = tabCount(in: window)

        /// Selecting the tab it is already on: the preview tab must stay disposable, or every
        /// click in the strip would quietly keep a tab.
        click(tab(named: "Artist", in: window))
        click(row("Customer", in: window))

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.tabCount(in: window) == beforeSelecting },
            """
            A single click only selects, so the preview tab must still be reused by the next table. \
            Tabs before: \(beforeSelecting), after: \(tabCount(in: window)).
            """
        )
    }

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
    /// rather than as a label or an identifier.
    private func row(_ name: String, in window: XCUIElement) -> XCUIElement {
        let match = window.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", "Table: \(name)"))
            .firstMatch
        XCTAssertTrue(match.waitToExist(timeout: 20), "The object browser must list \(name)")
        return match
    }

    private func tab(named name: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any)
            .matching(identifier: "editor-tab")
            .matching(NSPredicate(format: "label == %@", name))
            .firstMatch
    }

    private func click(_ element: XCUIElement) {
        clickAtCenter(element)
        settleBetweenClicks()
    }

    private func doubleClick(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        settleBetweenClicks()
    }

    /// A genuine delay, not a poll: there is no state to observe between two clicks, and the only
    /// thing being waited out is the window in which macOS would coalesce the next click into this
    /// one.
    private func settleBetweenClicks() {
        Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval)
    }

    /// The strip is drawn only once a connection holds more than one tab, so one tab reads as zero
    /// here. The tests compare counts rather than read a total, which holds either way.
    private func tabCount(in window: XCUIElement) -> Int {
        window.descendants(matching: .any).matching(identifier: "editor-tab").count
    }
}
