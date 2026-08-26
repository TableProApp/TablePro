import AppKit
import XCTest

/// Reordering by drag, after it stopped being a drag-and-drop session and became direct
/// manipulation. These cover the half of the strip that is fixed: a drag reorders, and it reorders
/// the same whether the tab is selected, unselected, or in a strip long enough to scroll.
///
/// They deliberately do not assert the window's origin. A press inside the leading region of the
/// titlebar still drags the window rather than the tab, which is the other half of #2438 and is
/// not fixed here.
final class EditorTabReorderUITests: UITestCase {
    func testDraggingATabReordersTheStrip() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        openTables(["Album", "Artist", "Customer"], in: window)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.tabLabels(in: window).count >= 3 },
            "The strip must show a tab per open table, got \(tabLabels(in: window))"
        )

        let before = tabLabels(in: window)

        drag(tab(named: before[0], in: window), onto: tab(named: before[2], in: window))

        let after = tabLabels(in: window)

        XCTAssertNotEqual(
            before,
            after,
            "Dragging the first tab across the strip must change the tab order, was \(before)"
        )
    }

    /// An unselected tab draws no surface of its own, so it is the one whose reorder is easiest to
    /// break by accident.
    func testDraggingAnUnselectedTabReordersTheStrip() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        openTables(["Album", "Artist", "Customer"], in: window)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.tabLabels(in: window).count >= 3 },
            "The strip must show a tab per open table, got \(tabLabels(in: window))"
        )

        let before = tabLabels(in: window)
        let selected = selectedTabLabel(in: window)
        let unselected = try XCTUnwrap(
            before.first { $0 != selected },
            "The strip must hold a tab other than the selected one"
        )

        drag(tab(named: unselected, in: window), onto: tab(named: before[before.count - 1], in: window))

        XCTAssertNotEqual(
            before,
            tabLabels(in: window),
            "Dragging an unselected tab must change the tab order, was \(before)"
        )
    }

    /// The control for the two above. If this fails too, the harness is not driving the strip at
    /// all and their results prove nothing.
    func testDraggingTheSelectedTabReordersTheStrip() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        openTables(["Album", "Artist", "Customer"], in: window)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.tabLabels(in: window).count >= 3 },
            "The strip must show a tab per open table, got \(tabLabels(in: window))"
        )

        let before = tabLabels(in: window)
        let selected = try XCTUnwrap(selectedTabLabel(in: window), "The strip must report a selected tab")
        let target = try XCTUnwrap(
            before.first { $0 != selected },
            "The strip must hold a tab other than the selected one"
        )

        drag(tab(named: selected, in: window), onto: tab(named: target, in: window))

        XCTAssertNotEqual(
            before,
            tabLabels(in: window),
            "Dragging the selected tab must change the tab order, was \(before)"
        )
    }

    /// Tabs stop shrinking at `minimumTabWidth` and the track scrolls instead, which moves the
    /// pointer's position in the viewport away from its position in the run of tabs. The reorder
    /// measures the pointer in the scroll view's content space for that reason; measured in the
    /// viewport it would place the drag one tab further along for every tab scrolled past.
    func testDraggingATabReordersAnOverflowingStrip() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        openTables(
            ["Album", "Artist", "Customer", "Employee", "Genre", "Invoice", "MediaType", "Playlist"],
            in: window
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { self.tabLabels(in: window).count >= 8 },
            "The strip must overflow before this proves anything, got \(tabLabels(in: window))"
        )

        let before = tabLabels(in: window)

        drag(tab(named: before[0], in: window), onto: tab(named: before[2], in: window))

        XCTAssertNotEqual(
            before,
            tabLabels(in: window),
            "Dragging a tab in an overflowing strip must change the tab order, was \(before)"
        )
    }

    private func readyWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 30))
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.outlines.firstMatch.outlineRows.count > 1 },
            "The object browser must list the sample database's tables"
        )
        return window
    }

    /// Double-clicked rather than clicked, because a single click opens a preview tab that the next
    /// table takes over, which would leave the strip holding one tab however many tables are opened.
    private func openTables(_ names: [String], in window: XCUIElement) {
        for name in names {
            let row = objectBrowserRow(name, in: window)
            XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list \(name)")
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
            Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval)
        }
    }

    private func tabElements(in window: XCUIElement) -> [XCUIElement] {
        window.descendants(matching: .any)
            .matching(identifier: "editor-tab")
            .allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    private func tabLabels(in window: XCUIElement) -> [String] {
        tabElements(in: window).map { $0.label }
    }

    private func selectedTabLabel(in window: XCUIElement) -> String? {
        tabElements(in: window).first { $0.isSelected }?.label
    }

    private func tab(named name: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any)
            .matching(identifier: "editor-tab")
            .matching(NSPredicate(format: "label == %@", name))
            .firstMatch
    }

    /// `click(forDuration:thenDragTo:)` is the macOS spelling. The iOS `press(forDuration:...)`
    /// compiles here and drives nothing: measured at HEAD, it left the tab order unchanged even on
    /// the selected tab, which real events do reorder, so it was reading the harness rather than
    /// the strip.
    private func drag(_ source: XCUIElement, onto destination: XCUIElement) {
        XCTAssertTrue(waitUntilHittable(source, timeout: 20), "The dragged tab must be hittable")
        XCTAssertTrue(waitUntilHittable(destination, timeout: 20), "The drop target tab must be hittable")
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(
                forDuration: 0.6,
                thenDragTo: destination.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            )
        Thread.sleep(forTimeInterval: 1.0)
    }
}
