import XCTest

// The strip lives in a titlebar accessory, so AppKit's own window drag claims every press on a tab
// unless `EditorTabInteractionView` refuses `mouseDownCanMoveWindow`. Checking the order alone would
// pass with the window sliding across the screen (#2438).
final class EditorTabReorderUITests: UITestCase {
    func testDraggingATabReordersTheStripWithoutMovingTheWindow() throws {
        let tables = ["album", "artist", "genre"]
        let launch = try launchWithFixture([ConnectionSeed(tabs: tables.map { SeededTab.table($0) })])
        let window = launch.window

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.editorTabTitles(in: window) == tables },
            "The strip must restore a tab per table, got \(editorTabTitles(in: window))"
        )
        let origin = window.frame.origin
        let dragged = editorTab(titled: "album", in: window)
        let target = editorTab(titled: "genre", in: window)
        XCTAssertTrue(waitUntilHittable(dragged, timeout: 20), "The dragged tab must be hittable")
        XCTAssertTrue(waitUntilHittable(target, timeout: 20), "The drop target tab must be hittable")

        // A press and drag in one movement, the way a person does it. `press(forDuration:...)` is the iOS
        // spelling: it compiles on macOS and drives nothing.
        dragged.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.02, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))

        // Same tabs in a new order: a drag that tore the tab off would change the order too.
        XCTAssertTrue(
            waitForPredicate(timeout: 15) {
                let titles = self.editorTabTitles(in: window)
                return titles.first != "album" && titles.sorted() == tables.sorted()
            },
            "Dragging album across the strip must reorder it, was \(tables), now \(editorTabTitles(in: window))"
        )
        XCTAssertEqual(window.frame.origin, origin, "Dragging a tab must move the tab, never the window")
    }
}
