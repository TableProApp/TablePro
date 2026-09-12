//
//  ResultMapModeUITests.swift
//  TableProUITests
//

import AppKit
import XCTest

/// Map is the only result mode gated on what the result holds rather than on the kind of tab, and
/// clicking a shape to select its row is the half of #2532 that no unit test can prove end to end.
///
/// SQLite reports `sqlite3_column_decltype` verbatim, so a column declared `POLYGON` classifies as
/// spatial with no extension and no server. That is what keeps this deterministic.
final class ResultMapModeUITests: UITestCase {
    /// One polygon, deliberately large. After Fit to Result it covers nearly the whole pane, so a
    /// click at the centre of the map is inside it whatever camera MapKit settles on.
    private static let spatialSetup = """
    CREATE TABLE IF NOT EXISTS map_probe (name TEXT, shape POLYGON);
    DELETE FROM map_probe;
    INSERT INTO map_probe VALUES ('block', 'SRID=4326;POLYGON((-122.52 37.70,-122.35 37.70,-122.35 37.83,-122.52 37.83,-122.52 37.70))');
    SELECT name, shape FROM map_probe;
    """

    private static let plainQuery = "SELECT 1 AS n;"

    func testMapAppearsOnlyWhileTheResultHoldsAGeometryColumn() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        runSpatialSetup(in: app)

        let modePicker = window.radioGroups["results-view-mode-picker"].firstMatch
        XCTAssertTrue(modePicker.waitToExist(timeout: 30), "The result must expose its view modes")
        XCTAssertTrue(
            waitForPredicate(timeout: 30, { modePicker.radioButtons["Map"].firstMatch.exists }),
            "A geometry column must put Map in the switcher"
        )

        runPlainQuery(in: app)

        XCTAssertTrue(
            waitForPredicate(timeout: 30, { !modePicker.radioButtons["Map"].firstMatch.exists }),
            "A result with no geometry column must take the Map segment away again"
        )
        XCTAssertTrue(modePicker.radioButtons["Data"].firstMatch.exists, "The other modes stay")
    }

    /// Leaving Map with no way back is the defect this feature would otherwise inherit: a mode that
    /// leaves the available set takes its switcher segment and every View menu item with it, and
    /// those items carry no key equivalent.
    func testATabLeftOnMapLandsOnDataWhenTheNextResultHasNoGeometry() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        runSpatialSetup(in: app)
        let modePicker = window.radioGroups["results-view-mode-picker"].firstMatch
        XCTAssertTrue(modePicker.waitToExist(timeout: 30))
        guard chooseMap(in: modePicker) else {
            throw XCTSkip("The Map segment never appeared, so there is nothing to leave")
        }

        runPlainQuery(in: app)

        XCTAssertTrue(
            waitForPredicate(timeout: 30, { !modePicker.radioButtons["Map"].firstMatch.exists }),
            "Map must leave the switcher once the result has no geometry"
        )
        let data = modePicker.radioButtons["Data"].firstMatch
        XCTAssertTrue(data.waitToExist(timeout: 10))
        XCTAssertEqual(
            data.value as? Int, 1,
            "The tab must land on Data rather than stay on a mode it can no longer offer"
        )
    }

    /// The click half of the request. Driven through XCUITest because it is the only thing here
    /// that posts real events: an `osascript` click does not reach the map, and neither does it
    /// reach the data grid, so it can prove nothing either way.
    func testClickingAShapeSelectsItsRow() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        runSpatialSetup(in: app)
        let modePicker = window.radioGroups["results-view-mode-picker"].firstMatch
        XCTAssertTrue(modePicker.waitToExist(timeout: 30))
        guard chooseMap(in: modePicker) else {
            throw XCTSkip("The Map segment never appeared")
        }

        let map = window.descendants(matching: .any)["result-map"].firstMatch
        XCTAssertTrue(map.waitToExist(timeout: 30), "Choosing Map must show the map pane")
        /// MapKit needs a moment to place the camera before a coordinate under the pointer means
        /// anything.
        _ = waitForPredicate(timeout: 10, { map.frame.width > 100 })

        /// A point offset from the element rather than a child element: the map publishes no
        /// per-shape accessibility children, so there is nothing to address by identifier.
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        /// Read the status bar while still in Map mode. Switching to Data remounts the grid, which
        /// restores the tab's own stored selection over the live one, so that route cannot observe
        /// a selection the map just made.
        let readout = window.staticTexts["result-status-readout"].firstMatch
        XCTAssertTrue(readout.waitToExist(timeout: 20), "Map mode still reports what the result holds")

        let selected = waitForPredicate(timeout: 20) {
            let text = (readout.value as? String) ?? readout.label
            return text.contains("selected")
        }
        XCTAssertTrue(
            selected,
            "Clicking a shape must select its row; readout said \((readout.value as? String) ?? readout.label)"
        )
    }

    // MARK: - Helpers

    private func chooseMap(in modePicker: XCUIElement) -> Bool {
        let map = modePicker.radioButtons["Map"].firstMatch
        guard waitForPredicate(timeout: 30, { map.exists && map.isHittable }) else { return false }
        map.click()
        return true
    }

    /// Creating a table and inserting a row is a destructive run, so the execution gate puts a
    /// sheet in front of it, and the statements only run once it is confirmed.
    private func runSpatialSetup(in app: XCUIApplication) {
        openEditor(in: app)
        paste(Self.spatialSetup, into: app)
        openExecuteMenu(in: app).menuItems["Execute All Statements"].click()
        let confirm = app.windows.firstMatch.sheets.firstMatch.buttons["Execute"]
        if confirm.waitToExist(timeout: 15) { confirm.click() }
    }

    private func runPlainQuery(in app: XCUIApplication) {
        openEditor(in: app)
        paste(Self.plainQuery, into: app)
        app.typeKey(.return, modifierFlags: .command)
    }

    private func openEditor(in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitToExist(timeout: 15))
        queryEditor.click()
    }

    /// The editor's own bracket and quote completion rewrites parentheses as they are typed, and a
    /// WKT polygon is nothing but parentheses. The pasteboard reaches the buffer intact.
    private func paste(_ text: String, into app: XCUIApplication) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        app.typeKey("v", modifierFlags: .command)
    }

    /// The control is a split button: its leading half runs the query and only its trailing chevron
    /// opens the menu, so a plain `click()` would execute instead of opening. Cmd+Return runs the
    /// statement under the cursor alone, which is not enough for a setup that creates a table.
    private func openExecuteMenu(in app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        let executeMenu = window.descendants(matching: .any)
            .matching(identifier: "query-execute-menu")
            .firstMatch
        XCTAssertTrue(
            waitUntilHittable(executeMenu, timeout: 15),
            "The editor toolbar must expose the Execute split button"
        )
        executeMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
        return window.menus.firstMatch
    }
}
