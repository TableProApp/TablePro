import SQLite3
import XCTest

// A plain cell publishes as static text and a cell with a picker as a combo box, so a cell is found by
// the position its label opens with, whatever its type.
internal struct FixtureGrid {
    internal let element: XCUIElement
    internal let app: XCUIApplication
    internal let objectBrowser: XCUIElement

    internal func cell(row: Int, column: Int) -> XCUIElement {
        element.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Row \(row), column \(column): "))
            .firstMatch
    }

    internal func value(row: Int, column: Int) -> String? {
        let cell = cell(row: row, column: column)
        guard cell.exists else { return nil }
        return cell.value as? String
    }

    internal func waitForValue(_ expected: String, row: Int, column: Int, timeout: TimeInterval = 20) -> Bool {
        UITestPoll.until(timeout: timeout) { value(row: row, column: column) == expected }
    }

    internal func header(_ column: String) -> XCUIElement {
        element.buttons
            .matching(NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@",
                "Column: \(column)",
                "Column: \(column), "
            ))
            .firstMatch
    }

    // XCUITest reads every row, cell and header as obscured, so a click is a point taken off the grid.
    // On the 1024pt runner the object browser overlaps the grid's leading edge, so the point stays right of it.
    internal func point(inside frame: CGRect) -> XCUICoordinate {
        let clearOfBrowser = objectBrowser.exists ? objectBrowser.frame.maxX + 8 : frame.minX
        let x = frame.midX >= clearOfBrowser ? frame.midX : min(frame.maxX - 4, clearOfBrowser)
        let origin = element.frame.origin
        return element.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x - origin.x, dy: frame.midY - origin.y))
    }

    internal func cellPoint(row: Int, column: Int) -> XCUICoordinate {
        let cell = cell(row: row, column: column)
        XCTAssertTrue(cell.waitToExist(timeout: 20), "Row \(row) must publish column \(column)")
        return point(inside: cell.frame)
    }

    internal func clickCell(row: Int, column: Int) {
        cellPoint(row: row, column: column).click()
    }

    internal func editCell(row: Int, column: Int, to text: String) {
        clickCell(row: row, column: column)
        app.typeKey(.return, modifierFlags: [])
        app.typeKey("a", modifierFlags: .command)
        app.typeText(text)
        app.typeKey(.return, modifierFlags: [])
    }

    internal func clickHeader(_ column: String, rightClick: Bool = false) {
        let header = header(column)
        XCTAssertTrue(header.waitToExist(timeout: 20), "The grid must publish a \(column) header")
        let target = point(inside: header.frame)
        if rightClick {
            target.rightClick()
        } else {
            target.click()
        }
    }
}

internal enum FixtureFile {
    // Nil until the statement can run, so a caller can poll for a table the app has not created yet.
    internal static func rows(_ sql: String, in databaseURL: URL) -> [[String]]? {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(handle, 5_000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let columns = sqlite3_column_count(statement)
            rows.append((0 ..< columns).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "NULL"
            })
        }
        return rows
    }

    internal static func execute(_ sql: String, in databaseURL: URL) -> Bool {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return false }
        sqlite3_busy_timeout(handle, 5_000)
        return sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }
}

extension UITestCase {
    internal func fixtureGrid(in window: XCUIElement, app: XCUIApplication) -> FixtureGrid {
        FixtureGrid(element: dataGrid(in: window), app: app, objectBrowser: objectBrowser(in: window))
    }

    internal func launchWithFixtureTable(
        _ table: String,
        safeModeLevel: String = "silent"
    ) throws -> (launch: FixtureLaunch, grid: FixtureGrid) {
        let launch = try launchWithFixture([ConnectionSeed(safeModeLevel: safeModeLevel, tabs: [.table(table)])])
        let grid = fixtureGrid(in: launch.window, app: launch.app)
        XCTAssertTrue(waitForClickableRows(in: grid.element), "The restored \(table) tab must load its rows")
        return (launch, grid)
    }

    internal func openFromObjectBrowser(_ table: String, in launch: FixtureLaunch) -> FixtureGrid {
        let row = objectBrowserRow(table, in: launch.window)
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list \(table)")
        clickAtCenter(row)
        let grid = fixtureGrid(in: launch.window, app: launch.app)
        XCTAssertTrue(waitForClickableRows(in: grid.element), "\(table) must load its rows")
        return grid
    }

    // Hosted rows report themselves disabled and never become hittable, so the menu is raised at a point.
    internal func rightClickInObjectBrowser(_ name: String, in window: XCUIElement) {
        let row = objectBrowserRow(name, in: window)
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list \(name)")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
    }

    internal func tabsTitled(_ title: String, in window: XCUIElement) -> XCUIElementQuery {
        window.descendants(matching: .any)
            .matching(identifier: "editor-tab")
            .matching(NSPredicate(format: "label == %@", title))
    }

    internal func editorTabCount(in window: XCUIElement) -> Int {
        window.descendants(matching: .any).matching(identifier: "editor-tab").count
    }
}
