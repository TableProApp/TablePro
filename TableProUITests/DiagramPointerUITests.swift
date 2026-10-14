import XCTest

// Zoom In reaches a diagram once it is clicked, Command and a scroll zoom it, and a click or a drag on a
// zoomed diagram lands on what is drawn under the pointer, not at the pointer times the zoom.
final class DiagramPointerUITests: UITestCase {
    func testZoomingAndDraggingATableOnTheERDiagram() throws {
        let launch = try launchWithFixture()
        let window = launch.window
        let app = launch.app

        XCTAssertTrue(app.menuBars.firstMatch.waitToExist(timeout: 20), "The app must publish its menu bar")
        menuItem("View ER Diagram", under: "Database", in: app).click()
        let canvas = window.scrollViews.matching(identifier: "er-diagram-canvas").firstMatch
        XCTAssertTrue(canvas.waitToExist(timeout: 30), "The ER diagram must open on the fixture")
        XCTAssertTrue(
            canvas.descendants(matching: .layoutItem).firstMatch.waitToExist(timeout: 30),
            "The diagram must draw the fixture's tables"
        )

        let zoomLevel = window.buttons["Reset Zoom"].firstMatch
        XCTAssertTrue(zoomLevel.waitToExist(timeout: 10), "The diagram must show its zoom level")
        zoomLevel.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { (zoomLevel.value as? String) == "100%" }, "Reset Zoom must land on 100%")

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).click()
        app.typeShortcut(.zoomIn)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (zoomLevel.value as? String) == "150%" },
            "With the diagram focused, Zoom In must step it to the next level"
        )

        XCUIElement.perform(withKeyModifiers: .command) {
            canvas.scroll(byDeltaX: 0, deltaY: 6)
        }
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { (zoomLevel.value as? String) != "150%" },
            "Command and a scroll over the diagram must change its zoom, not only scroll it"
        )

        zoomLevel.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { (zoomLevel.value as? String) == "100%" }, "Reset Zoom must land on 100%")
        let zoomOut = window.buttons["Zoom Out"].firstMatch
        for _ in 0 ..< 3 {
            zoomOut.click()
        }
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (zoomLevel.value as? String) == "50%" },
            "Three zoom-out steps from 100% must land on 50%"
        )

        // Clear of the edges, where a drag starts the auto-pan.
        let inner = canvas.frame.insetBy(dx: 60, dy: 60)
        let table = try XCTUnwrap(
            canvas.descendants(matching: .layoutItem).allElementsBoundByIndex.first { inner.contains($0.frame) },
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
        XCTAssertTrue(
            waitForPredicate(timeout: 5) {
                abs(table.frame.minX - before.minX - 60) < 6 && abs(table.frame.minY - before.minY - 40) < 6
            },
            "A dragged table must follow the pointer, not move by the zoom's fraction of it: "
                + "\(before) became \(table.frame)"
        )
    }
}
