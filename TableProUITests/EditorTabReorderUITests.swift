import AppKit
import XCTest

/// Reordering by drag, now that AppKit owns the press rather than arbitrating for it.
///
/// The window's origin is asserted here. The strip lives in a titlebar accessory, so AppKit's own
/// window drag is a claimant on every press that lands on a tab, and `EditorTabInteractionView`
/// answers `false` to `mouseDownCanMoveWindow` precisely so it can never win. A test that only
/// checks the order would pass just as happily with the window sliding across the screen.
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

        XCTAssertTrue(
            waitForTabOrder(toChangeFrom: before, in: window),
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

        XCTAssertTrue(
            waitForTabOrder(toChangeFrom: before, in: window),
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

        XCTAssertTrue(
            waitForTabOrder(toChangeFrom: before, in: window),
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

        // Not `before[0]`: once the track scrolls, the leading tabs stay in the accessibility tree
        // at frames outside the viewport, and the pointer cannot land on one.
        let reachable = onScreenTabs(in: window).map { $0.label }
        XCTAssertGreaterThanOrEqual(
            reachable.count,
            4,
            "The viewport must hold four tabs to drag between, showed \(reachable) of \(before)"
        )

        // Interior tabs only. A tab at either edge of a scrolled track is half outside the
        // viewport, and a click at its centre lands on the chrome beside the track rather than on
        // the tab, so the drag never reaches the strip at all.
        drag(tab(named: reachable[1], in: window), onto: tab(named: reachable[reachable.count - 2], in: window))

        XCTAssertTrue(
            waitForTabOrder(toChangeFrom: before, in: window),
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
    private func drag(_ source: XCUIElement, onto destination: XCUIElement, hold: TimeInterval = 0.6) {
        XCTAssertTrue(waitUntilHittable(source, timeout: 20), "The dragged tab must be hittable")
        XCTAssertTrue(waitUntilHittable(destination, timeout: 20), "The drop target tab must be hittable")
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(
                forDuration: hold,
                thenDragTo: destination.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            )
    }

    /// The strip animates the move and commits it on release, so the new order arrives some time
    /// after the gesture returns. Waiting for it rather than sleeping a fixed amount is what keeps
    /// this readable on a loaded machine: a sleep long enough for CI is dead time on every local
    /// run, and one short enough for a local run reads the pre-drag order on CI and reports the
    /// reorder as broken.
    private func waitForTabOrder(toChangeFrom before: [String], in window: XCUIElement) -> Bool {
        waitForPredicate(timeout: 15) { self.tabLabels(in: window) != before }
    }

    /// The guard the strip's home makes necessary. A press on a tab inside a titlebar accessory is
    /// one AppKit would otherwise turn into a window drag, and this is the assertion that says it
    /// does not: the reported symptom of #2438 was the whole window travelling with the pointer.
    func testDraggingATabNeverMovesTheWindow() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        openTables(["Album", "Artist", "Customer"], in: window)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.tabLabels(in: window).count >= 3 },
            "The strip must show a tab per open table, got \(tabLabels(in: window))"
        )

        let before = tabLabels(in: window)
        let origin = window.frame.origin

        drag(tab(named: before[0], in: window), onto: tab(named: before[2], in: window), hold: 0.02)

        XCTAssertTrue(
            waitForTabOrder(toChangeFrom: before, in: window),
            "Dragging a tab must change the tab order, was \(before)"
        )
        XCTAssertEqual(
            window.frame.origin,
            origin,
            "Dragging a tab must move the tab, never the window"
        )
    }

    /// A user presses and drags in one movement. The suite's other cases hold for 0.6s first,
    /// which is not a gesture anybody makes, and the arbitration this replaces behaved differently
    /// under the two.
    func testAFastDragReordersTheStrip() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        openTables(["Album", "Artist", "Customer"], in: window)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.tabLabels(in: window).count >= 3 },
            "The strip must show a tab per open table, got \(tabLabels(in: window))"
        )

        let before = tabLabels(in: window)

        drag(tab(named: before[0], in: window), onto: tab(named: before[1], in: window), hold: 0.02)

        XCTAssertTrue(
            waitForTabOrder(toChangeFrom: before, in: window),
            "A drag with no hold before it must reorder, was \(before)"
        )
    }

    /// The tabs the pointer can actually reach.
    ///
    /// Once the strip overflows, the track scrolls and the tabs outside the viewport stay in the
    /// accessibility tree with frames the pointer cannot land on. Dragging one of those is not a
    /// weaker version of the gesture, it is no gesture at all.
    private func onScreenTabs(in window: XCUIElement) -> [XCUIElement] {
        tabElements(in: window).filter { $0.exists && $0.isHittable }
    }
}
