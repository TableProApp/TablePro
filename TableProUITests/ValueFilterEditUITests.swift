//
//  ValueFilterEditUITests.swift
//  TableProUITests
//

import AppKit
import XCTest

final class ValueFilterEditUITests: UITestCase {
    private static let table = "Employee"
    private static let filteredColumn = "Title"
    private static let keptTitle = "IT Staff"
    private static let editedColumnPosition = 2
    private static let editedValue = "Edited Under Filter"

    func testDiscardingAnEditMadeUnderAValueFilterRestoresTheEditedRow() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        let grid = openTable(in: window)

        let secondRowBefore = try cellValue(row: 2, in: grid)
        let lastRowBefore = try cellValue(row: 8, in: grid)

        rightClickHeader(Self.filteredColumn, in: grid)
        let filterValues = contextMenuItem("Filter Values…", in: app)
        XCTAssertTrue(filterValues.waitToExist(timeout: 10), "The header menu must offer Filter Values…")
        filterValues.click()
        keepOnly(Self.keptTitle, in: window)

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.currentCellValue(row: 2, in: grid) == lastRowBefore },
            "Under the filter the table's last row must be shown second"
        )

        editCell(row: 2, in: grid, app: app, to: Self.editedValue)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.currentCellValue(row: 2, in: grid) == Self.editedValue },
            "The edit must land on the row shown second"
        )

        rightClickHeader(Self.filteredColumn, in: grid)
        let clearFilter = contextMenuItem("Clear Value Filter", in: app)
        XCTAssertTrue(clearFilter.waitToExist(timeout: 10), "A filtered column's menu must offer Clear Value Filter")
        clearFilter.click()

        let discard = app.buttons["Discard"].firstMatch
        XCTAssertTrue(discard.waitToExist(timeout: 10), "Clearing the filter over a pending edit must ask first")
        discard.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.currentCellValue(row: 8, in: grid) == lastRowBefore },
            "Discard must put back the value of the row that was edited"
        )
        XCTAssertEqual(
            currentCellValue(row: 2, in: grid),
            secondRowBefore,
            "Discard must not write the edited row's value into the row that shared its position"
        )
    }

    // MARK: - Helpers

    private func openTable(in window: XCUIElement) -> XCUIElement {
        XCTAssertTrue(window.waitToExist(timeout: 60), "The sample database produced no window")
        let row = objectBrowserRow(Self.table, in: window)
        XCTAssertTrue(row.waitToExist(timeout: 30), "The object browser must list \(Self.table)")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(waitForClickableRows(in: grid, timeout: 30), "\(Self.table) must load its rows")
        return grid
    }

    private func rightClickHeader(_ column: String, in grid: XCUIElement) {
        let header = grid.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Column: \(column)"))
            .firstMatch
        XCTAssertTrue(header.waitToExist(timeout: 30), "The grid must publish a \(column) header")
        point(at: header.frame, in: grid).rightClick()
    }

    private func keepOnly(_ value: String, in window: XCUIElement) {
        let popover = window.popovers.firstMatch
        let search = popover.searchFields["value-filter-search"].firstMatch
        XCTAssertTrue(search.waitToExist(timeout: 10), "Filter Values… must open the value filter")
        search.typeText(value)

        let selectAll = popover.checkBoxes.matching(NSPredicate(format: "label == %@", "Select All")).firstMatch
        XCTAssertTrue(waitUntilHittable(selectAll, timeout: 10), "The value filter must offer Select All")
        selectAll.click()

        let valueToggle = popover.checkBoxes.matching(identifier: "value-filter-value").firstMatch
        XCTAssertTrue(waitUntilHittable(valueToggle, timeout: 10), "The search must leave \(value) in the list")
        valueToggle.click()

        let apply = popover.buttons["Apply"].firstMatch
        XCTAssertTrue(waitUntilHittable(apply, timeout: 10), "The value filter must offer Apply")
        apply.click()
        XCTAssertTrue(popover.waitForNonExistence(timeout: 10), "Apply must close the value filter")
    }

    private func editCell(row: Int, in grid: XCUIElement, app: XCUIApplication, to value: String) {
        let cell = cellElement(row: row, in: grid)
        XCTAssertTrue(cell.waitToExist(timeout: 10), "Row \(row) must publish its cells")
        point(at: cell.frame, in: grid).click()
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        app.typeKey("a", modifierFlags: .command)
        app.typeText(value)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    }

    private func point(at frame: CGRect, in grid: XCUIElement) -> XCUICoordinate {
        let origin = grid.frame.origin
        return grid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - origin.x, dy: frame.midY - origin.y))
    }

    private func cellElement(row: Int, in grid: XCUIElement) -> XCUIElement {
        grid.staticTexts
            .matching(NSPredicate(
                format: "label BEGINSWITH %@",
                "Row \(row), column \(Self.editedColumnPosition): "
            ))
            .firstMatch
    }

    private func currentCellValue(row: Int, in grid: XCUIElement) -> String? {
        let cell = cellElement(row: row, in: grid)
        guard cell.exists else { return nil }
        return cell.value as? String
    }

    private func cellValue(row: Int, in grid: XCUIElement) throws -> String {
        _ = waitForPredicate(timeout: 20) { self.currentCellValue(row: row, in: grid) != nil }
        return try XCTUnwrap(currentCellValue(row: row, in: grid), "The grid must publish row \(row)'s cells")
    }
}
