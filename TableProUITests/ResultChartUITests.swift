//
//  ResultChartUITests.swift
//  TableProUITests
//

import XCTest

final class ResultChartUITests: UITestCase {
    func testAnUnlicensedChartBuildsNoResultData() throws {
        let app = try launchWithSampleDatabase()
        runQuery(in: app)

        let window = app.windows.firstMatch
        let modePicker = window.radioGroups["results-view-mode-picker"].firstMatch
        XCTAssertTrue(modePicker.waitToExist(timeout: 10), "The result must expose its view modes")

        let chart = modePicker.radioButtons["Chart"].firstMatch
        XCTAssertTrue(
            waitUntilHittable(chart, timeout: 10),
            "Column-bearing results must offer an interactive Chart mode"
        )
        chart.click()

        let gate = window.staticTexts["pro-feature-gate-resultCharts"].firstMatch
        XCTAssertTrue(gate.waitToExist(timeout: 10), "An unlicensed chart must show its license gate")
        XCTAssertFalse(window.descendants(matching: .any).matching(identifier: "result-chart").firstMatch.exists)
        XCTAssertFalse(
            window.descendants(matching: .any).matching(identifier: "result-chart-type-picker").firstMatch.exists,
            "Locked chart controls must not expose result metadata behind the license gate"
        )
    }

    private func runQuery(in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        editor.click()
        app.typeText("SELECT Name, Milliseconds FROM Track ORDER BY TrackId LIMIT 12;")
        app.typeKey(.return, modifierFlags: .command)

        let grid = app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 15), "The query must produce a result grid")
    }
}
