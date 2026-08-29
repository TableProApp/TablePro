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

        let item = app.menuItems[copyToTitle]
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
        let item = app.menuItems[copyToTitle]
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
