//
//  DiagramPointerUITests.swift
//  TableProUITests
//
//  A click or a drag on a zoomed diagram lands on what is drawn under the pointer. The SwiftUI
//  gestures these replaced resolved every point at the pointer's position times the zoom, which only
//  a real click through the window shows.
//

import XCTest

final class DiagramPointerUITests: UITestCase {
    func testClickingAndDraggingATableOnAZoomedOutERDiagram() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["Database"].click()
        menuBar.menuItems["View ER Diagram"].click()

        let canvas = window.scrollViews.matching(identifier: "er-diagram-canvas").firstMatch
        XCTAssertTrue(canvas.waitToExist(timeout: 30), "The ER diagram must open on the sample database")
        zoomOutToHalf(in: window)

        let table = try XCTUnwrap(
            elementWellInside(canvas.descendants(matching: .layoutItem), of: canvas.frame),
            "A table must be on screen at 50%"
        )
        table.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { table.isSelected },
            "A click on a table in a zoomed diagram must select that table"
        )

        let before = table.frame
        let grip = table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        grip.click(forDuration: 0.3, thenDragTo: grip.withOffset(CGVector(dx: 60, dy: 40)))
        let followed = waitForPredicate(timeout: 5) {
            abs(table.frame.minX - before.minX - 60) < 6 && abs(table.frame.minY - before.minY - 40) < 6
        }
        XCTAssertTrue(
            followed,
            "A dragged table must follow the pointer, not move by the zoom's fraction of it: \(before) became \(table.frame)"
        )
    }

    func testClickingAPlanStepOnAZoomedOutDiagramOpensItsDetails() throws {
        let app = try launchWithSampleDatabase()
        runQuery("EXPLAIN QUERY PLAN SELECT * FROM Track JOIN Album ON Track.AlbumId = Album.AlbumId;", in: app)

        let window = app.windows.firstMatch
        let canvas = window.scrollViews.matching(identifier: "query-plan-diagram").firstMatch
        XCTAssertTrue(canvas.waitToExist(timeout: 20), "Diagram mode must show the plan canvas")
        zoomOutToHalf(in: window)

        let step = try XCTUnwrap(
            elementWellInside(canvas.buttons, of: canvas.frame),
            "The plan must publish its steps as buttons"
        )
        XCTAssertTrue(
            waitUntilHittable(step, timeout: 5),
            "A pointer query must find the step, or VoiceOver cannot read it under the pointer"
        )
        step.click()

        let detail = app.descendants(matching: .any).matching(identifier: "query-plan-detail-pane").firstMatch
        XCTAssertTrue(detail.waitToExist(timeout: 5), "A click on a step in a zoomed diagram must open that step's details")
    }

    // MARK: - Helpers

    private func zoomOutToHalf(in window: XCUIElement) {
        let zoomLevel = window.buttons["Reset Zoom"].firstMatch
        XCTAssertTrue(zoomLevel.waitToExist(timeout: 10), "The diagram must show its zoom level")
        zoomLevel.click()
        let zoomOut = window.buttons["Zoom Out"].firstMatch
        for _ in 0..<3 {
            zoomOut.click()
        }
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (zoomLevel.value as? String) == "50%" },
            "Three zoom-out steps from 100% must land on 50%"
        )
    }

    /// An element near the canvas edge can start the edge auto-pan, which moves it under a drag for
    /// reasons this test is not about.
    private func elementWellInside(_ query: XCUIElementQuery, of container: CGRect) -> XCUIElement? {
        let inner = container.insetBy(dx: 60, dy: 60)
        return query.allElementsBoundByIndex.first { inner.contains($0.frame) }
    }

    private func runQuery(_ sql: String, in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        typeQuery(sql, in: app)
        app.typeKey(.return, modifierFlags: .command)
    }
}
