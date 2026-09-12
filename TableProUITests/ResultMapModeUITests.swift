//
//  ResultMapModeUITests.swift
//  TableProUITests
//

import XCTest

/// Map is the only result mode gated on what the result holds rather than on the kind of tab, so
/// the segment appearing and disappearing is the part a unit test over `ResultsModeAvailability`
/// cannot prove end to end: it has to survive the real classifier, the real status bar and the real
/// execution path.
///
/// SQLite reports `sqlite3_column_decltype` verbatim, so a column declared `POINT` classifies as
/// spatial with no extension and no server. That keeps this deterministic.
final class ResultMapModeUITests: UITestCase {
    func testMapAppearsOnlyWhileTheResultHoldsAGeometryColumn() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        runQuery(
            """
            DROP TABLE IF EXISTS tp_map_probe;
            CREATE TABLE tp_map_probe (name TEXT, geom POINT);
            INSERT INTO tp_map_probe VALUES ('a', 'SRID=4326;POINT(-122.4194 37.7749)');
            SELECT name, geom FROM tp_map_probe;
            """,
            in: app
        )

        let modePicker = window.radioGroups["results-view-mode-picker"].firstMatch
        XCTAssertTrue(modePicker.waitToExist(timeout: 20), "The result must expose its view modes")
        XCTAssertTrue(
            waitForSegment("Map", in: modePicker, toExist: true, timeout: 20),
            "A geometry column must put Map in the switcher"
        )

        runQuery("SELECT 1 AS n;", in: app)

        XCTAssertTrue(
            waitForSegment("Map", in: modePicker, toExist: false, timeout: 20),
            "A result with no geometry column must take the Map segment away again"
        )
        XCTAssertTrue(
            waitForSegment("Data", in: modePicker, toExist: true, timeout: 10),
            "The other modes stay"
        )
    }

    /// Leaving Map and finding no way back is the defect this feature would otherwise inherit: a
    /// mode that leaves the available set takes its switcher segment and every View menu item with
    /// it, and those items carry no key equivalent.
    func testATabLeftOnMapLandsOnDataWhenTheNextResultHasNoGeometry() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        runQuery(
            """
            DROP TABLE IF EXISTS tp_map_probe2;
            CREATE TABLE tp_map_probe2 (geom POINT);
            INSERT INTO tp_map_probe2 VALUES ('SRID=4326;POINT(1 2)');
            SELECT geom FROM tp_map_probe2;
            """,
            in: app
        )

        let modePicker = window.radioGroups["results-view-mode-picker"].firstMatch
        XCTAssertTrue(modePicker.waitToExist(timeout: 20))
        XCTAssertTrue(waitForSegment("Map", in: modePicker, toExist: true, timeout: 20))

        let mapSegment = modePicker.radioButtons["Map"].firstMatch
        XCTAssertTrue(mapSegment.isHittable, "The Map segment must be clickable")
        mapSegment.click()

        let map = window.descendants(matching: .any)["result-map"].firstMatch
        XCTAssertTrue(map.waitToExist(timeout: 20), "Choosing Map must show the map pane")

        runQuery("SELECT 1 AS n;", in: app)

        XCTAssertTrue(
            waitForSegment("Map", in: modePicker, toExist: false, timeout: 20),
            "Map must leave the switcher once the result has no geometry"
        )
        let data = modePicker.radioButtons["Data"].firstMatch
        XCTAssertTrue(data.waitToExist(timeout: 10))
        XCTAssertEqual(
            data.value as? Int, 1,
            "The tab must land on Data rather than stay on a mode it can no longer offer"
        )
    }

    // MARK: - Helpers

    private func waitForSegment(
        _ label: String,
        in picker: XCUIElement,
        toExist shouldExist: Bool,
        timeout: TimeInterval
    ) -> Bool {
        let segment = picker.radioButtons[label].firstMatch
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if segment.exists == shouldExist { return true }
            usleep(200_000)
        }
        return segment.exists == shouldExist
    }

    private func runQuery(_ sql: String, in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitToExist(timeout: 10))
        queryEditor.click()
        app.typeText(sql)
        app.typeKey(.return, modifierFlags: .command)
    }
}
