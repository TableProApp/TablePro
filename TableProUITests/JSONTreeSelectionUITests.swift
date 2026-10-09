//
//  JSONTreeSelectionUITests.swift
//  TableProUITests
//
//  The JSON viewer's Tree mode selects rows like any outline: a click selects, Command-C copies
//  the row, a link row offers Open Link, and Escape clears the selection before it closes the
//  popover.
//
//  The value comes from a query of a literal, so it is read-only and opens the viewer rather than
//  the editor. Chinook has no JSON value with a link in it.
//

import AppKit
import XCTest

final class JSONTreeSelectionUITests: UITestCase {
    private static let query = #"SELECT '{"name":"Acme","site":"https://example.com/docs"}' AS payload;"#

    func testCommandCCopiesTheSelectedRow() throws {
        let app = try launchWithSampleDatabase()
        let (popover, outline) = try openTreeViewer(in: app)
        let nameRow = outline.outlineRows.element(boundBy: 0)

        clickAtCenter(nameRow)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { nameRow.isSelected },
            "A click on a tree row must select it"
        )
        app.typeKey("c", modifierFlags: .command)

        /// The copy is read back inside the app: pasted into the tree's own filter field.
        let filter = popover.searchFields["tree-filter"].firstMatch
        XCTAssertTrue(filter.waitToExist(timeout: 10), "The tree must keep its filter field")
        filter.click()
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { (filter.value as? String) == "Acme" },
            "Command-C on the name row must copy its value; the filter holds '\(filter.value as? String ?? "nil")'"
        )
    }

    func testALinkRowOffersOpenLink() throws {
        let app = try launchWithSampleDatabase()
        let (_, outline) = try openTreeViewer(in: app)
        let siteRow = outline.outlineRows.element(boundBy: 1)

        siteRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()

        XCTAssertTrue(
            contextMenuItem("Open Link", in: app).waitToExist(timeout: 10),
            "The menu of a row whose value is a link must offer Open Link"
        )
        XCTAssertTrue(contextMenuItem("Copy Link", in: app).exists, "and Copy Link beside it")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    func testEscapeClearsTheSelectionBeforeItClosesThePopover() throws {
        let app = try launchWithSampleDatabase()
        let (popover, outline) = try openTreeViewer(in: app)
        let nameRow = outline.outlineRows.element(boundBy: 0)

        clickAtCenter(nameRow)
        XCTAssertTrue(waitForPredicate(timeout: 10) { nameRow.isSelected }, "A click on a tree row must select it")

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !nameRow.isSelected },
            "The first Escape must clear the row selection"
        )
        XCTAssertTrue(popover.exists, "The first Escape must leave the popover open")

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !popover.exists },
            "With nothing selected, Escape must close the popover"
        )
    }

    // MARK: - Helpers

    /// Runs the query, shows its column as JSON, opens the cell with Return and switches the
    /// viewer to Tree.
    private func openTreeViewer(in app: XCUIApplication) throws -> (popover: XCUIElement, outline: XCUIElement) {
        let window = app.windows.firstMatch
        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10), "A new tab must open on a query editor")
        editor.click()
        paste(Self.query, into: app)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (editor.value as? String)?.contains("payload") == true },
            "The editor must hold the query; got '\(editor.value as? String ?? "nil")'"
        )

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .command)
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 20), "The query must produce a result grid")
        XCTAssertTrue(waitForClickableRows(in: grid), "The query must return its row")

        showAsJSON(column: "payload", in: grid, app: app)

        gridPoint(in: grid, of: window, dy: 52).click()
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        let popover = window.popovers.firstMatch
        XCTAssertTrue(popover.waitToExist(timeout: 15), "Return on a JSON cell must open the JSON viewer")
        let tree = popover.radioButtons["Tree"].firstMatch
        let treeSegment = tree.exists ? tree : popover.buttons["Tree"].firstMatch
        XCTAssertTrue(treeSegment.waitToExist(timeout: 10), "The viewer must offer a Tree mode")
        treeSegment.click()

        let outline = popover.outlines.matching(identifier: "tree-outline").firstMatch
        XCTAssertTrue(outline.waitToExist(timeout: 10), "Tree mode must show the value as an outline")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { outline.outlineRows.count >= 2 },
            "The outline must list the name and site keys"
        )
        return (popover, outline)
    }

    /// A header is clicked through a coordinate taken off the grid, as `HeaderSortUITests` explains.
    private func showAsJSON(column: String, in grid: XCUIElement, app: XCUIApplication) {
        let header = grid.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Column: \(column)"))
            .firstMatch
        XCTAssertTrue(header.waitToExist(timeout: 20), "The grid must publish a \(column) header")
        let frame = header.frame
        let origin = grid.frame.origin
        grid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - origin.x, dy: frame.midY - origin.y))
            .rightClick()

        let displayAs = contextMenuItem("Display As", in: app)
        XCTAssertTrue(displayAs.waitToExist(timeout: 10), "The header menu of a text column must offer Display As")
        displayAs.click()
        let json = contextMenuItem("JSON", in: app)
        XCTAssertTrue(json.waitToExist(timeout: 10), "Display As must offer JSON for a text column")
        json.click()
    }

    /// Typed text would go through the editor's quote and bracket pairing, which rewrites a JSON
    /// literal as it is typed. The pasteboard reaches the editor with the statement intact.
    private func paste(_ text: String, into app: XCUIApplication) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        app.typeKey("v", modifierFlags: .command)
    }
}
