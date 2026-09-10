import AppKit
import XCTest

/// Moving a tab into a window of its own, and the two things that go wrong once one connection is
/// hosted by two windows: the tab is lost from both, or the shared session goes down with whichever
/// window closes first.
///
/// Three tables, not two. `ConnectionWindowPaneResolver.showsTabStrip` hides the strip at one tab,
/// the way Safari hides its tab bar, so a source window left holding a single tab would have no
/// strip for these to read. The detached window has none either, which is why it is identified by
/// its title rather than by a tab element.
final class EditorTabDetachUITests: UITestCase {
    private static let tables = ["Album", "Artist", "Customer"]

    func testMoveTabToNewWindowTakesTheTabOutOfTheStrip() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        openTables(Self.tables, in: window)
        XCTAssertTrue(
            waitForPredicate(timeout: 25) { self.tabLabels(in: window).count >= 3 },
            "The strip must show a tab per open table, got \(tabLabels(in: window))"
        )

        let before = tabLabels(in: window)
        let moved = try XCTUnwrap(before.last, "The strip must hold a tab to move")

        detach(tabNamed: moved, in: window, of: app)

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { app.windows.count >= 2 },
            "Move Tab to New Window must open a second window"
        )
        /// Asked of every window rather than of `window`, which is a query and re-resolves: once
        /// the move opens a second window, `app.windows.firstMatch` can be that one, and the
        /// assertion then reads the tab it was looking for in the window it was moved into.
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.someWindow(in: app, holds: before.filter { $0 != moved }) },
            "A window must hold the tabs that stayed behind, windows show \(self.tabsPerWindow(in: app))"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 20) {
                app.windows.allElementsBoundByIndex.contains { $0.title.contains(moved) }
            },
            "A window must be titled for the moved tab, titles are \(windowTitles(in: app))"
        )
    }

    /// The session belongs to the connection, not to either window.
    func testClosingTheDetachedWindowLeavesTheOriginalWorking() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        openTables(Self.tables, in: window)
        XCTAssertTrue(waitForPredicate(timeout: 25) { self.tabLabels(in: window).count >= 3 })

        let before = tabLabels(in: window)
        let moved = try XCTUnwrap(before.last)
        detach(tabNamed: moved, in: window, of: app)
        XCTAssertTrue(waitForPredicate(timeout: 20) { app.windows.count >= 2 })

        let detached = try XCTUnwrap(
            app.windows.allElementsBoundByIndex.first { $0.title.contains(moved) },
            "The detached window must be findable by title"
        )
        detached.buttons[XCUIIdentifierCloseWindow].click()

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { app.windows.count == 1 },
            "Closing the detached window must close it rather than empty it"
        )
        /// Compared against what the strip held before the move rather than against a number: the
        /// sample database opens a tab of its own, so the total is not the count of tables opened
        /// here.
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.someWindow(in: app, holds: before.filter { $0 != moved }) },
            "The remaining window keeps the other tabs, windows show \(self.tabsPerWindow(in: app)) of \(before)"
        )
    }

    /// A tab with a query still running is claimed by the coordinator that started it, so the
    /// command stands down rather than orphaning the result.
    func testTheCommandIsOfferedOnAnIdleTab() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        openTables(Self.tables, in: window)
        XCTAssertTrue(waitForPredicate(timeout: 25) { self.tabLabels(in: window).count >= 3 })

        let target = try XCTUnwrap(tabLabels(in: window).last)
        tab(named: target, in: window).rightClick()

        let item = app.menuItems.matching(identifier: "Move Tab to New Window").firstMatch
        XCTAssertTrue(item.waitToExist(timeout: 5), "The command must be listed")
        XCTAssertTrue(item.isEnabled, "It must be offered on an idle tab among others")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }

    // MARK: - Helpers

    private func detach(tabNamed name: String, in window: XCUIElement, of app: XCUIApplication) {
        let target = tab(named: name, in: window)
        XCTAssertTrue(waitUntilHittable(target, timeout: 20), "The tab must be hittable")
        target.rightClick()
        let item = app.menuItems.matching(identifier: "Move Tab to New Window").firstMatch
        XCTAssertTrue(item.waitToExist(timeout: 5), "The command must be listed")
        item.click()
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

    private func openTables(_ names: [String], in window: XCUIElement) {
        for name in names {
            let row = objectBrowserRow(name, in: window)
            XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list \(name)")
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
            Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval)
        }
    }

    private func tabLabels(in window: XCUIElement) -> [String] {
        window.descendants(matching: .any)
            .matching(identifier: "editor-tab")
            .allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { $0.label }
    }

    /// Whether any window's strip holds exactly these tabs, in this order.
    private func someWindow(in app: XCUIApplication, holds tabs: [String]) -> Bool {
        app.windows.allElementsBoundByIndex.contains { tabLabels(in: $0) == tabs }
    }

    private func tabsPerWindow(in app: XCUIApplication) -> [[String]] {
        app.windows.allElementsBoundByIndex.map { tabLabels(in: $0) }
    }

    private func windowTitles(in app: XCUIApplication) -> [String] {
        app.windows.allElementsBoundByIndex.map { $0.title }
    }

    private func tab(named name: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any)
            .matching(identifier: "editor-tab")
            .matching(NSPredicate(format: "label == %@", name))
            .firstMatch
    }
}
