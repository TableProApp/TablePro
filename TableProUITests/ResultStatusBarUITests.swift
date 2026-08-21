//
//  ResultStatusBarUITests.swift
//  TableProUITests
//

import XCTest

final class ResultStatusBarUITests: UITestCase {
    func testTheModeSwitcherAndTheReadoutShareTheBottomBar() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        let grid = runQuery(in: app)

        let modePicker = window.radioGroups["results-view-mode-picker"].firstMatch
        XCTAssertTrue(modePicker.waitToExist(timeout: 10), "The result must expose its view modes")

        let readout = window.staticTexts["result-status-readout"].firstMatch
        XCTAssertTrue(readout.waitToExist(timeout: 10), "The status bar must report what the result holds")

        /// Automatic grammar agreement is resolved from the String Catalog. A key that never made it
        /// into the catalog renders its markup verbatim, which ships "^[12 rows](inflect: true)".
        let text = (readout.value as? String) ?? readout.label
        XCTAssertFalse(text.isEmpty, "The readout must say something")
        XCTAssertFalse(
            text.contains("^["),
            "Inflection markup leaked into the UI, so the key is missing from the String Catalog: \(text)"
        )

        XCTAssertGreaterThanOrEqual(
            readout.frame.minY, grid.frame.maxY,
            "The status bar belongs below the result it describes"
        )
        XCTAssertGreaterThanOrEqual(
            modePicker.frame.minY, grid.frame.maxY,
            "The view switcher leads that same bar rather than taking a band of its own"
        )
        XCTAssertLessThan(
            modePicker.frame.maxX, readout.frame.minX,
            "The switcher comes before the readout on the bar"
        )
    }

    /// The readout is anchored to the leading edge rather than centred between two clusters, so it
    /// starts near the pane's left edge whatever the controls on the right happen to be.
    func testTheReadoutIsAnchoredToTheLeadingEdge() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        let grid = runQuery(in: app)

        let readout = window.staticTexts["result-status-readout"].firstMatch
        XCTAssertTrue(readout.waitToExist(timeout: 10))

        let modePicker = window.radioGroups["results-view-mode-picker"].firstMatch
        XCTAssertTrue(modePicker.waitToExist(timeout: 10))
        let offsetIntoPane = modePicker.frame.minX - grid.frame.minX
        XCTAssertLessThan(
            offsetIntoPane, 40,
            "The leading cluster must start at the pane's edge, not drift with the width of the controls"
        )
    }

    /// Opening one table after another used to strip the bar back to the mode switcher and refill it
    /// in stages. The transient frames are not observable from here, because the clear and reload
    /// outrun XCUITest's polling, so this asserts the part that is: every control the bar owns is
    /// still there once each table has settled, on a tab that is being reused rather than replaced.
    func testTheBarKeepsItsControlsAcrossTableSwitches() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        for table in ["Album", "Artist", "Track"] {
            let row = objectBrowserRow(table, in: window)
            guard row.waitToExist(timeout: 15) else {
                XCTFail("The object browser must list \(table)")
                return
            }
            clickAtCenter(row)

            let readout = window.staticTexts["result-status-readout"].firstMatch
            XCTAssertTrue(readout.waitToExist(timeout: 15), "\(table): the readout must survive the switch")

            for identifier in ["result-status-columns", "result-status-filters", "pagination-page-size"] {
                XCTAssertTrue(
                    window.descendants(matching: .any)[identifier].firstMatch.waitToExist(timeout: 15),
                    "\(table): \(identifier) left the bar"
                )
            }

            XCTAssertTrue(
                window.descendants(matching: .any)["pagination-page-indicator"].firstMatch.exists,
                "\(table): the page indicator left the bar"
            )
        }
    }

    @discardableResult
    private func runQuery(in app: XCUIApplication) -> XCUIElement {
        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        editor.click()
        app.typeText("SELECT Name, Milliseconds FROM Track ORDER BY TrackId LIMIT 12;")
        app.typeKey(.return, modifierFlags: .command)

        let grid = app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 15), "The query must produce a result grid")
        return grid
    }
}
