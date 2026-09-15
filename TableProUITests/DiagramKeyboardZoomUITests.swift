//
//  DiagramKeyboardZoomUITests.swift
//  TableProUITests
//
//  View > Zoom In goes to whatever has focus: a diagram once it is clicked, the editor's text size
//  otherwise. The plan sits under the SQL editor, which is the case that has to tell the two apart.
//

import XCTest

final class DiagramKeyboardZoomUITests: UITestCase {
    func testCommandEqualsZoomsTheFocusedPlanAndLeavesItAloneFromTheEditor() throws {
        let app = try launchWithSampleDatabase()
        runQuery("EXPLAIN QUERY PLAN SELECT * FROM Track JOIN Album ON Track.AlbumId = Album.AlbumId;", in: app)

        let window = app.windows.firstMatch
        let canvas = window.scrollViews.matching(identifier: "query-plan-diagram").firstMatch
        XCTAssertTrue(canvas.waitToExist(timeout: 20), "Diagram mode must show the plan canvas")
        let zoomLevel = window.buttons["Reset Zoom"].firstMatch
        XCTAssertTrue(zoomLevel.waitToExist(timeout: 10), "The plan must show its zoom level")
        zoomLevel.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { (zoomLevel.value as? String) == "100%" })

        editorTextView(in: app).click()
        app.typeKey("=", modifierFlags: .command)
        XCTAssertFalse(
            waitForPredicate(timeout: 2) { (zoomLevel.value as? String) != "100%" },
            "With the editor focused, Zoom In must leave the plan alone"
        )
        app.typeKey("-", modifierFlags: .command)

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).click()
        app.typeKey("=", modifierFlags: .command)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (zoomLevel.value as? String) == "150%" },
            "With the plan focused, Zoom In must step the plan to the next level"
        )
    }

    func testCommandEqualsZoomsAClickedERDiagram() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["Database"].click()
        menuBar.menuItems["View ER Diagram"].click()

        let canvas = window.scrollViews.matching(identifier: "er-diagram-canvas").firstMatch
        XCTAssertTrue(canvas.waitToExist(timeout: 30), "The ER diagram must open on the sample database")
        let zoomLevel = window.buttons["Reset Zoom"].firstMatch
        XCTAssertTrue(zoomLevel.waitToExist(timeout: 10), "The diagram must show its zoom level")
        zoomLevel.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { (zoomLevel.value as? String) == "100%" })

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).click()
        app.typeKey("-", modifierFlags: .command)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (zoomLevel.value as? String) == "75%" },
            "With the diagram focused, Zoom Out must step the diagram to the next level down"
        )

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(editorTextView(in: app).waitToExist(timeout: 10), "A new query tab must open")
        app.typeKey("[", modifierFlags: [.command, .shift])
        XCTAssertTrue(canvas.waitToExist(timeout: 10), "Show Previous Tab must return to the diagram")
        app.typeKey("=", modifierFlags: .command)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (zoomLevel.value as? String) == "100%" },
            "Returning to a loaded diagram tab must give it focus without a click"
        )
    }

    // MARK: - Helpers

    private func runQuery(_ sql: String, in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitToExist(timeout: 10))
        queryEditor.click()
        app.typeText(sql)
        app.typeKey(.return, modifierFlags: .command)
    }
}
