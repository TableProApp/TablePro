import XCTest

// A plan is an ordinary result set: it rides the result chooser and can be pinned. SQLite makes the plan
// deterministic, with no server to reach.
final class QueryPlanResultUITests: UITestCase {
    private static let query = "SELECT * FROM track JOIN album ON track.album_id = album.id;"

    func testExplainShowsAPlanWhoseStepsOpenAndZoom() throws {
        let launch = try launchWithFixture()
        let app = launch.app
        let window = launch.window

        typeQuery(Self.query, in: window)
        app.typeShortcut(.explainQuery)

        let chooser = resultSetChooser(in: window)
        XCTAssertTrue(chooser.waitToExist(timeout: 20), "A plan must arrive as a result set")
        let canvas = window.scrollViews.matching(identifier: "query-plan-diagram").firstMatch
        XCTAssertTrue(canvas.waitToExist(timeout: 20), "A plan opens in Diagram mode")
        let zoomLevel = window.buttons["Reset Zoom"].firstMatch
        XCTAssertTrue(zoomLevel.waitToExist(timeout: 10), "The plan must show its zoom level")

        zoomLevel.click()
        expectZoom("100%", on: zoomLevel)
        let zoomOut = window.buttons["Zoom Out"].firstMatch
        for level in ["75%", "67%", "50%"] {
            zoomOut.click()
            expectZoom(level, on: zoomLevel)
        }
        // Diagram mode shows a step's details in a popover, so the search starts at the app.
        let detail = app.descendants(matching: .any).matching(identifier: "query-plan-detail-pane").firstMatch
        XCTAssertFalse(detail.exists, "No step is open before one is clicked")
        let step = try XCTUnwrap(stepWellInside(canvas), "The plan must publish its steps as buttons")
        XCTAssertTrue(
            waitUntilHittable(step, timeout: 5),
            "A pointer query must find the step, or VoiceOver cannot read it under the pointer"
        )
        step.click()
        XCTAssertTrue(detail.waitToExist(timeout: 5), "A click on a step in a zoomed-out diagram must open its details")

        let modes = window.radioGroups["query-plan-mode-picker"].firstMatch
        modes.radioButtons["Tree"].click()
        let outline = window.outlines["query-plan-outline"].firstMatch
        XCTAssertTrue(outline.waitToExist(timeout: 10), "Tree mode must show the plan outline")
        XCTAssertGreaterThan(outline.outlineRows.count, 0, "The outline must list the plan's steps")
        modes.radioButtons["Diagram"].click()
        XCTAssertTrue(canvas.waitToExist(timeout: 10), "Diagram mode must come back")

        // Zoom In goes to whatever has focus. Exactly one step from 100% proves the press made from the
        // editor never reached the plan.
        zoomLevel.click()
        expectZoom("100%", on: zoomLevel)
        editorTextView(in: window).click()
        app.typeShortcut(.zoomIn)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).click()
        app.typeShortcut(.zoomIn)
        expectZoom("150%", on: zoomLevel)

        // A re-run replaces every result that is not pinned.
        app.typeShortcut(.pinResult)
        editorTextView(in: window).click()
        app.typeShortcut(.explainQuery)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { chooser.title.contains("of 2") || chooser.title.hasSuffix("/2") },
            "A pinned plan must survive a second Explain beside the new one, got \(chooser.title)"
        )
    }

    private func expectZoom(_ level: String, on zoomLevel: XCUIElement) {
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (zoomLevel.value as? String) == level },
            "The plan must sit at \(level), got \(zoomLevel.value as? String ?? "nothing")"
        )
    }

    // A step near the edge can start the canvas's edge auto-pan under the pointer.
    private func stepWellInside(_ canvas: XCUIElement) -> XCUIElement? {
        let inner = canvas.frame.insetBy(dx: 60, dy: 60)
        return canvas.buttons.allElementsBoundByIndex.first { inner.contains($0.frame) }
    }
}
