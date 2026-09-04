import XCTest

/// Issue #2487. Copy To has to be reachable from the object browser's own contextual menu, and the
/// sheet it opens has to name the source and refuse to continue before a target is chosen.
///
/// The sample database is SQLite, which has one database and no `CREATE DATABASE`, so Duplicate
/// Database is deliberately not exercised here: it needs a server this runner does not have. Its
/// contract is asserted without one in `DatabaseTreeMenuSpecTests` and `ObjectCopySessionTests`.
final class CopyObjectsUITests: UITestCase {
    private let copyToTitle = "Copy To…"

    func testCopyToIsOnATableRowsContextualMenu() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        openContextMenu(onRow: "Album", in: window, of: app)

        let item = contextMenuItem(copyToTitle, in: app)
        XCTAssertTrue(
            item.waitToExist(timeout: 10),
            "Copy To must be reachable from a table row's contextual menu"
        )
        dismissMenu(in: app)
    }

    func testChoosingCopyToOpensTheSheetNamingTheSource() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        openContextMenu(onRow: "Album", in: window, of: app)
        let item = contextMenuItem(copyToTitle, in: app)
        XCTAssertTrue(item.waitToExist(timeout: 10))
        item.click()

        let objects = window.descendants(matching: .any)
            .matching(identifier: "copy-objects-list").firstMatch
        let target = window.descendants(matching: .any)
            .matching(identifier: "copy-objects-target").firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { objects.exists || target.exists },
            "Copy To must open a sheet offering the objects and a target"
        )

        /// Nothing has been written and nothing can be: the sheet is still on its first step, so
        /// Cancel is the whole interaction under test.
        let cancel = window.buttons["Cancel"].firstMatch
        if cancel.waitToExist(timeout: 10) {
            cancel.click()
        }
    }

    /// The object search used to be a plain text field wearing a magnifying glass, so Escape went
    /// straight past it to the sheet's Cancel: narrowing the list and changing your mind about the
    /// search threw away the target, the content choice and every tick with it. An `NSSearchField`
    /// takes the key itself while it holds text.
    func testEscapeInTheObjectSearchClearsItRatherThanClosingTheSheet() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        openContextMenu(onRow: "Album", in: window, of: app)
        let item = contextMenuItem(copyToTitle, in: app)
        XCTAssertTrue(item.waitToExist(timeout: 10))
        item.click()

        let search = window.descendants(matching: .any)
            .matching(identifier: "copy-objects-search").firstMatch
        XCTAssertTrue(search.waitToExist(timeout: 20), "The sheet must offer a search field")
        XCTAssertTrue(waitUntilHittable(search, timeout: 20))
        search.click()
        app.typeText("Album")

        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(
            search.exists,
            "Escape belongs to the search field while it holds text; the sheet must still be open"
        )

        /// Empty now, so this Escape is the one that leaves.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !search.exists },
            "Escape on an empty search field closes the sheet"
        )
    }

    /// A filter narrows one table's rows without leaving the object list, and the row has to say so
    /// afterwards: a filter that is set and invisible is a copy that quietly carries less than the
    /// user thinks it does.
    func testAPerTableFilterIsSetFromTheObjectListAndShownOnTheRow() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        try openCopyToSheet(onRow: "Album", in: window, of: app)

        let funnel = window.descendants(matching: .any)
            .matching(identifier: "copy-objects-row-filter-Album").firstMatch
        XCTAssertTrue(funnel.waitToExist(timeout: 20), "A table row must offer a row filter")
        XCTAssertTrue(waitUntilHittable(funnel, timeout: 20))
        funnel.click()

        let field = app.descendants(matching: .any).matching(identifier: "row-scope-filter").firstMatch
        XCTAssertTrue(field.waitToExist(timeout: 20), "The filter popover must offer a WHERE field")
        XCTAssertTrue(waitUntilHittable(field, timeout: 20))
        field.click()
        app.typeText("AlbumId > 10")

        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitToExist(timeout: 10))
        done.click()

        let summary = window.descendants(matching: .any)
            .matching(identifier: "copy-objects-row-scope-Album").firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { summary.exists },
            "The row must show the filter it now carries"
        )
        let spoken = [summary.label, (summary.value as? String) ?? ""].joined(separator: " ")
        XCTAssertTrue(
            spoken.contains("AlbumId"),
            "The summary must name the filter. label=\(summary.label) value=\(String(describing: summary.value))"
        )

        app.typeKey(.escape, modifierFlags: [])
    }

    /// A filter is one expression. Text carrying a second statement is refused rather than spliced
    /// into the `SELECT` the copy runs, and Continue stays out of reach until it is gone.
    func testAFilterCarryingASecondStatementBlocksContinue() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        try openCopyToSheet(onRow: "Album", in: window, of: app)

        let funnel = window.descendants(matching: .any)
            .matching(identifier: "copy-objects-row-filter-Album").firstMatch
        XCTAssertTrue(funnel.waitToExist(timeout: 20))
        XCTAssertTrue(waitUntilHittable(funnel, timeout: 20))
        funnel.click()

        let field = app.descendants(matching: .any).matching(identifier: "row-scope-filter").firstMatch
        XCTAssertTrue(field.waitToExist(timeout: 20))
        XCTAssertTrue(waitUntilHittable(field, timeout: 20))
        field.click()
        app.typeText("1=1; DROP TABLE Album")

        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitToExist(timeout: 10))
        done.click()

        let cont = window.buttons["Continue"].firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { cont.exists && !cont.isEnabled },
            "Continue must stay unavailable while a filter holds a second statement"
        )

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Helpers

    private func openCopyToSheet(
        onRow name: String,
        in window: XCUIElement,
        of app: XCUIApplication
    ) throws {
        openContextMenu(onRow: name, in: window, of: app)
        let item = contextMenuItem(copyToTitle, in: app)
        XCTAssertTrue(item.waitToExist(timeout: 10))
        item.click()
        let list = window.descendants(matching: .any)
            .matching(identifier: "copy-objects-list").firstMatch
        XCTAssertTrue(list.waitToExist(timeout: 20), "Copy To must open its object list")
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

    /// The tree's rows are hosted cells that AppKit reports as disabled, so the menu is raised
    /// through a coordinate rather than through the element.
    private func openContextMenu(onRow name: String, in window: XCUIElement, of app: XCUIApplication) {
        let row = objectBrowserRow(name, in: window)
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list \(name)")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
    }

    private func dismissMenu(in app: XCUIApplication) {
        app.typeKey(.escape, modifierFlags: [])
    }
}
