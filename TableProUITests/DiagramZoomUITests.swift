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

    func testZoomOutStopsAtTheLadderFloor() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["Database"].click()
        menuBar.menuItems["View ER Diagram"].click()

        let canvas = window.scrollViews.matching(identifier: "er-diagram-canvas").firstMatch
        XCTAssertTrue(canvas.waitToExist(timeout: 30), "The ER diagram must open on the sample database")
        let zoomLevel = window.buttons["Reset Zoom"].firstMatch
        XCTAssertTrue(zoomLevel.waitToExist(timeout: 10), "The diagram must show its zoom level")
        _ = settledValue(of: zoomLevel)
        zoomLevel.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { (zoomLevel.value as? String) == "100%" })

        let zoomOut = window.buttons["Zoom Out"].firstMatch
        for level in ["75%", "67%", "50%", "33%", "25%", "10%", "5%"] {
            zoomOut.click()
            XCTAssertTrue(
                waitForPredicate(timeout: 5) { (zoomLevel.value as? String) == level },
                "Zoom Out must step down the ladder to \(level)"
            )
        }
        XCTAssertFalse(zoomOut.isEnabled, "Zoom Out must dim at 5% instead of dropping to 1%")

        canvas.click()
        let viewMenu = menuBar.menuBarItems["View"]
        viewMenu.click()
        XCTAssertFalse(viewMenu.menuItems["Zoom Out"].isEnabled, "View > Zoom Out must dim for a diagram at 5%")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(zoomLevel.value as? String, "5%")
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
