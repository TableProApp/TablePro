import XCTest

/// #2535. A cell holding SVG markup used to show its source and nothing else. It now opens on the
/// drawing, with the markup one segment away.
///
/// The value arrives from a query rather than a table, because Chinook carries no image column and
/// a result of a literal is read-only, which is the path the reporter described.
final class CellImageViewerUITests: UITestCase {
    private let markup = "<svg><rect/></svg>"
    private let query = "SELECT '<svg><rect/></svg>' AS logo;"

    func testAnSvgCellOpensOnTheImageSegmentWithItsMarkupBeside() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        let editor = openQueryTab(in: app)

        typeSvgQuery(in: app)
        XCTAssertTrue(
            waitForValue(query, in: editor, timeout: 5),
            "The editor must hold the query; got '\(editor.value as? String ?? "nil")'"
        )

        let grid = runQuery(in: app)
        openCell(in: grid, of: window, app: app)

        XCTAssertTrue(
            waitForPredicate(timeout: 15) { self.segment("Image", in: window).exists },
            "An SVG cell must offer an Image segment"
        )
        let sourceSegment = segment("Source", in: window)
        XCTAssertTrue(sourceSegment.exists, "The stored markup must stay one segment away")

        clickAtCenter(sourceSegment)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.markupIsVisible(in: window) },
            "The Source segment must show the stored markup"
        )
    }

    func testAPlainTextCellStillOpensTheInlineViewer() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        let editor = openQueryTab(in: app)

        app.typeText("SELECT 1 AS n;")
        XCTAssertTrue(waitForValue("SELECT 1 AS n;", in: editor, timeout: 5))

        let grid = runQuery(in: app)
        openCell(in: grid, of: window, app: app)

        XCTAssertFalse(
            segment("Image", in: window).waitToExist(timeout: 3),
            "A value that is not an image must not gain an Image segment"
        )
    }

    // MARK: - Helpers

    /// The editor auto-closes `'`, so the closing quote is never typed: it is already there, and
    /// the caret jumps past it before the rest of the statement goes in.
    private func typeSvgQuery(in app: XCUIApplication) {
        app.typeText("SELECT '")
        app.typeText(markup)
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: .command)
        app.typeText(" AS logo;")
    }

    private func runQuery(in app: XCUIApplication) -> XCUIElement {
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .command)
        let grid = app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 20), "The query must produce a result grid")
        XCTAssertTrue(grid.tableRows.element(boundBy: 0).waitToExist(timeout: 20))
        return grid
    }

    /// A coordinate, never the row or the cell: the grid publishes its columns as siblings of its
    /// rows and later in the tree, so XCUITest reads both as obscured and refuses to click them.
    /// `Return` rather than a second click, because the click path is gated on inline editing.
    private func openCell(in grid: XCUIElement, of window: XCUIElement, app: XCUIApplication) {
        gridPoint(in: grid, of: window, dy: 52).click()
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    }

    /// A segmented control publishes its segments as radio buttons, and the CI runner has been seen
    /// publishing the same controls as plain buttons, so both are asked.
    private func segment(_ title: String, in window: XCUIElement) -> XCUIElement {
        let radio = window.radioButtons[title]
        return radio.exists ? radio : window.buttons[title]
    }

    private func markupIsVisible(in window: XCUIElement) -> Bool {
        window.textViews.allElementsBoundByIndex.contains {
            ($0.value as? String)?.contains("<svg>") == true
        }
    }

    private func openQueryTab(in app: XCUIApplication) -> XCUIElement {
        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        XCTAssertTrue(waitForValue("", in: editor, timeout: 5), "A new tab starts with an empty editor")
        return editor
    }

    private func waitForValue(_ expected: String, in element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitForPredicate(timeout: timeout) { (element.value as? String) == expected }
    }
}
