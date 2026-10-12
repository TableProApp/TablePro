//
//  ForeignKeyNavigationUITests.swift
//  TableProUITests
//
//  Following a foreign key leaves the tab it was followed from open. Chinook's Album.ArtistId
//  references Artist, and Album is the last column of that table, which is what the cell cursor
//  reaches by walking right.
//

import AppKit
import XCTest

final class ForeignKeyNavigationUITests: UITestCase {
    func testFollowingAReferenceKeepsTheTabItCameFrom() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        let grid = try albumGrid(in: app, window: window)

        /// Counted rather than asserted against a number: the sample database opens a tab of its
        /// own before this suite opens Album, and the strip publishes nothing while one tab is
        /// open, so what this pins is the increase.
        let tabsBefore = window.descendants(matching: .any)
            .matching(identifier: "editor-tab").count

        focusTheArtistIdCell(in: app, grid: grid)
        app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [])

        let openArtist = window.buttons["Open Artist"].firstMatch
        XCTAssertTrue(
            openArtist.waitToExist(timeout: 30),
            "Preview FK Reference must offer to open the referenced table"
        )
        clickAtCenter(openArtist)

        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                window.descendants(matching: .any)
                    .matching(identifier: "editor-tab").count > tabsBefore
            },
            "Following the reference must add a tab rather than retarget the one it came from"
        )
        /// Addressed as the tab rather than as a static text: the strip combines each tab's
        /// children into one accessibility element, so the drawn title is that element's label and
        /// is never published as a text of its own.
        XCTAssertTrue(
            waitForPredicate(timeout: 20) {
                window.descendants(matching: .any)
                    .matching(identifier: "editor-tab")
                    .matching(NSPredicate(format: "label == %@", "Album"))
                    .firstMatch.exists
            },
            "The Album tab must still be in the strip after the reference opened"
        )
    }

    // MARK: - Helpers

    private func readyWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 60), "The sample database produced no window")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.outlines.firstMatch.outlineRows.count > 1 },
            "The object browser must list the sample database's tables"
        )
        return window
    }

    private func albumGrid(in app: XCUIApplication, window: XCUIElement) throws -> XCUIElement {
        let row = window.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", "Table: Album"))
            .firstMatch
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list Album")
        clickAtCenter(row)

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "Album produced no data grid")
        XCTAssertTrue(waitForClickableRows(in: grid), "Album must load rows before a cell can be read")
        return grid
    }

    /// A point offset from the grid rather than a row or cell element, which XCUITest reads as
    /// obscured by the columns published beside them, with `dy` clearing the 42pt header. The cell
    /// cursor then walks right until it stops, which is Album's last column, `ArtistId`.
    private func focusTheArtistIdCell(in app: XCUIApplication, grid: XCUIElement) {
        grid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 60, dy: 70))
            .click()

        for _ in 0 ..< 5 {
            app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        }
    }
}
