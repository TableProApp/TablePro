//
//  ResultStatusBarUITests.swift
//  TableProUITests
//

import AppKit
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
    ///
    /// Runs at the default window width, where the bar draws every control inline. Rows-per-page
    /// folds into the page indicator once the pane is narrow, which
    /// `testEveryControlIsReachableOnceTheBarHasToFold` covers instead.
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

    /// A window narrow enough that the bar has to fold, which is the state it used to break in: its
    /// clusters were pinned at full width, so the whole tab content column laid out at 766pt and
    /// SwiftUI centred it inside the pane, leaving the edges unreachable. Measured at the window's
    /// own 720pt minimum that cost 163pt on each side, taking the grid's row numbers, its whole
    /// first column and the entire pagination cluster; at 1000pt it still cost 23pt a side.
    ///
    /// `existence` is not the assertion. Every one of those controls existed throughout; they were
    /// simply outside the window. `isHittable` is what tells the two apart.
    func testEveryControlIsReachableOnceTheBarHasToFold() throws {
        try skipUnlessTheScreenFitsThePinnedWindow()
        let app = try launchWithSampleDatabase(environment: pinnedEnvironment)
        let window = app.windows.firstMatch

        let row = objectBrowserRow("Track", in: window)
        guard row.waitToExist(timeout: 15) else {
            XCTFail("The object browser must list Track")
            return
        }
        clickAtCenter(row)

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 15), "Opening a table must produce a result grid")

        /// The pin is what puts the bar in its folded state, so a launch that came up at some other
        /// width would assert nothing. Checked rather than assumed.
        try XCTSkipUnless(
            abs(window.frame.width - Self.pinnedWindowSize.width) <= 1,
            "The window came up \(window.frame.width)pt wide instead of \(Self.pinnedWindowSize.width)pt, so the bar is not in its folded state"
        )

        /// The folded switcher is a pull-down rather than a segmented control, which is the cheapest
        /// proof from here that the bar really did give up chrome instead of overflowing.
        let modePicker = window.popUpButtons["results-view-mode-picker"].firstMatch
        XCTAssertTrue(modePicker.waitToExist(timeout: 10), "A folded bar carries the modes in a pull-down")
        XCTAssertTrue(modePicker.isHittable, "The mode pull-down must be reachable, not merely present")

        /// Columns and the page indicator have no menu-bar equivalent, so the bar keeps both at
        /// every width. Rows-per-page moves inside the page indicator's menu rather than leaving.
        let controls = ["result-status-columns", "result-status-highlight", "result-status-filters", "pagination-page-indicator"]
        for identifier in controls {
            let control = window.descendants(matching: .any)[identifier].firstMatch
            XCTAssertTrue(control.waitToExist(timeout: 10), "\(identifier) left the bar")
            XCTAssertTrue(control.isHittable, "\(identifier) is present but out of reach")
            expectInsideTheWindow(control, window, named: identifier)
        }

        expectInsideTheWindow(grid, window, named: "the grid")
    }

    /// The defect this guards was 163pt of overhang. `XCUIElement.frame` rounds, and a split
    /// divider can leave a control a point over the edge on a window whose origin is not on a whole
    /// point, so a point of slack keeps the assertion about the defect rather than about rounding.
    /// The exact geometry is asserted to the point in `ResultStatusBarLayoutTests`, which measures
    /// real view frames instead.
    private func expectInsideTheWindow(_ element: XCUIElement, _ window: XCUIElement, named name: String) {
        XCTAssertGreaterThanOrEqual(
            element.frame.minX, window.frame.minX - Self.edgeTolerance,
            "\(name) starts before the window's leading edge"
        )
        XCTAssertLessThanOrEqual(
            element.frame.maxX, window.frame.maxX + Self.edgeTolerance,
            "\(name) ends past the window's trailing edge"
        )
    }

    /// Wide enough that the sidebar still leaves a usable pane, narrow enough that the bar folds.
    /// Measured: the pull-down replaces the segmented switcher at or below this width.
    private static let pinnedWindowSize = CGSize(width: 1_000, height: 820)
    private static let edgeTolerance: CGFloat = 2

    private var pinnedEnvironment: [String: String] {
        ["TABLEPRO_SCREENSHOT_FRAME": "\(Int(Self.pinnedWindowSize.width))x\(Int(Self.pinnedWindowSize.height))"]
    }

    /// A screen that cannot hold the pinned window makes the launch come up at some other size, and
    /// the tier under test is then not the one on screen.
    private func skipUnlessTheScreenFitsThePinnedWindow() throws {
        let width = NSScreen.main?.frame.width ?? 0
        try XCTSkipUnless(
            width >= Self.pinnedWindowSize.width,
            "Needs a screen at least \(Int(Self.pinnedWindowSize.width))pt wide to hold the pinned window; this one is \(Int(width))pt"
        )
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
