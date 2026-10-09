//
//  InspectorGeometryFieldUITests.swift
//  TableProUITests
//

import XCTest

/// A geometry field in the row inspector opens on a map of its value, with the stored text one
/// segment away. SQLite reports a declared type verbatim, so `POLYGON` and `POINT` columns classify
/// as spatial with no extension and no server.
final class InspectorGeometryFieldUITests: UITestCase {
    private static let databaseSQL = """
    CREATE TABLE map_probe (name TEXT, shape POLYGON);
    INSERT INTO map_probe VALUES ('block', 'SRID=4326;POLYGON((-122.52 37.70,-122.35 37.70,-122.35 37.83,-122.52 37.83,-122.52 37.70))');
    CREATE TABLE map_empty (name TEXT, shape POINT);
    INSERT INTO map_empty VALUES ('nowhere', 'POINT EMPTY');
    """

    private let typedMarker = "ZZTOP"
    private let typedPoint = "POINT(1 2)"

    func testAGeometryFieldOpensOnItsMapWithTheTextOneSegmentAway() throws {
        let (app, window) = try openFirstRow(of: "map_probe")

        let map = mapElement(in: window)
        XCTAssertTrue(map.waitToExist(timeout: 30), "A drawable geometry must open on its map")

        choose("Text", in: window)
        let stored = textView(holding: "POLYGON", in: window)
        XCTAssertTrue(stored.waitToExist(timeout: 20), "Text must show the stored value")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !map.exists },
            "The map belongs to the Map segment and must leave with it"
        )

        choose("Map", in: window)
        XCTAssertTrue(map.waitToExist(timeout: 20), "Switching back must show the map again")

        choose("Text", in: window)
        XCTAssertTrue(stored.waitToExist(timeout: 20))
        stored.click()
        app.typeText(typedMarker)
        /// Looked up by what was typed: the caret lands wherever the click did, which may split the
        /// keyword the first lookup matched on.
        XCTAssertTrue(
            textView(holding: typedMarker, in: window).waitToExist(timeout: 20),
            "The text must stay editable, so what is typed has to land in it"
        )
    }

    /// The mode is decided when the field appears. One that followed the text would replace the
    /// editor with a map at the closing parenthesis, under the caret.
    func testTypingADrawableValueLeavesTheFieldOnText() throws {
        let (app, window) = try openFirstRow(of: "map_empty")

        let stored = textView(holding: "POINT EMPTY", in: window)
        XCTAssertTrue(
            stored.waitToExist(timeout: 30),
            "An empty geometry has nothing to draw, so its field opens on Text"
        )
        XCTAssertTrue(modePicker(in: window).exists, "The field still offers its Map segment")
        let map = mapElement(in: window)
        XCTAssertFalse(map.exists, "Nothing is drawn for an empty geometry")

        stored.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(typedPoint)

        let typed = textView(holding: typedPoint, in: window)
        XCTAssertTrue(typed.waitToExist(timeout: 20), "The typed value must land in the field")
        XCTAssertFalse(map.waitToExist(timeout: 3), "A value that became drawable must not move the field to Map")
        XCTAssertTrue(typed.exists, "The editor being typed in must stay on screen")

        choose("Map", in: window)
        XCTAssertTrue(map.waitToExist(timeout: 20), "The map draws the typed value before it is saved")
    }

    // MARK: - Helpers

    private func openFirstRow(of table: String) throws -> (XCUIApplication, XCUIElement) {
        try seedSQLiteSession(connectionNames: ["Geometry"], databaseSQL: Self.databaseSQL)
        let app = try launchApp()
        let window = app.windows.firstMatch

        let row = objectBrowserRow(table, in: window)
        XCTAssertTrue(row.waitToExist(timeout: 60), "The restored connection must list \(table)")
        clickAtCenter(row)
        showInspector(in: app)

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "\(table) must produce a grid")
        XCTAssertTrue(waitForClickableRows(in: grid), "\(table) must return its row")
        /// Past the 28pt header and inside the first row at every row height the setting offers.
        gridPoint(in: grid, of: window, dy: 40).click()
        return (app, window)
    }

    private func textView(holding text: String, in window: XCUIElement) -> XCUIElement {
        window.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
    }

    private func mapElement(in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any)["inspector-geometry-map"].firstMatch
    }

    private func modePicker(in window: XCUIElement) -> XCUIElement {
        window.radioGroups["inspector-geometry-mode"].firstMatch
    }

    private func choose(_ segment: String, in window: XCUIElement) {
        let button = modePicker(in: window).radioButtons[segment].firstMatch
        XCTAssertTrue(waitUntilHittable(button, timeout: 20), "The field must offer a \(segment) segment")
        button.click()
    }

    /// The inspector remembers whether it was open, and the menu item reads Hide Inspector once it
    /// is, which is the only handle on that state.
    private func showInspector(in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))
        menuBar.menuBarItems["View"].click()

        let show = menuBar.menuItems["Show Inspector"]
        if show.waitToExist(timeout: 5) {
            show.click()
            return
        }
        app.typeKey(.escape, modifierFlags: [])
    }
}
