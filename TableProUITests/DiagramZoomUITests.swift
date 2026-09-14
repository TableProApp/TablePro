//
//  DiagramZoomUITests.swift
//  TableProUITests
//
//  Command and a scroll over a diagram zoom it. The unit tests hand events straight to the scroll
//  view; this is the one that proves an event from the window reaches it with Command still held.
//

import XCTest

final class DiagramZoomUITests: UITestCase {
    func testCommandScrollZoomsTheERDiagram() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["Database"].click()
        menuBar.menuItems["View ER Diagram"].click()

        let canvas = window.scrollViews.matching(identifier: "er-diagram-canvas").firstMatch
        XCTAssertTrue(canvas.waitToExist(timeout: 30), "The ER diagram must open on the sample database")

        let zoomLevel = window.buttons["Reset Zoom"].firstMatch
        XCTAssertTrue(zoomLevel.waitToExist(timeout: 10), "The diagram must show its zoom level")
        let fitted = settledValue(of: zoomLevel)

        XCUIElement.perform(withKeyModifiers: .command) {
            canvas.scroll(byDeltaX: 0, deltaY: 6)
        }

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { (zoomLevel.value as? String) != fitted },
            "Command and a scroll over the diagram must change its zoom, not only scroll it"
        )
    }

    /// The diagram fits itself to the window once it has laid out, so the level read straight
    /// after opening can still be the 100% it starts at.
    private func settledValue(of element: XCUIElement) -> String? {
        var previous = element.value as? String
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.5)
            let current = element.value as? String
            if current == previous, current != nil { return current }
            previous = current
        }
        return previous
    }
}
