import XCTest

// #2235 and #2436: a single click opens a table in a preview tab the next click reuses; a double-click
// on the sidebar row or on the tab keeps it. The restored query tab keeps the tab strip on screen.
// Consecutive clicks never land on the same spot, so none can be coalesced into a double-click.
final class SidebarTableTabUITests: UITestCase {
    func testAPreviewTabIsReusedUntilItIsKept() throws {
        let launch = try launchWithFixture()
        let window = launch.window

        clickAtCenter(sidebarRow("album", in: window))
        XCTAssertTrue(waitForTabs(["album"], in: window), "A click must open the table in a tab")
        let previewing = tabCount(in: window)

        clickAtCenter(sidebarRow("artist", in: window))
        XCTAssertTrue(
            waitForTabs(["artist"], without: ["album"], in: window),
            "A second click must reuse the preview tab rather than open another"
        )
        XCTAssertEqual(tabCount(in: window), previewing)

        doubleClickAtCenter(sidebarRow("genre", in: window))
        XCTAssertTrue(waitForTabs(["genre"], without: ["artist"], in: window), "A double-click opens in the preview tab")
        clickAtCenter(sidebarRow("track", in: window))
        XCTAssertTrue(
            waitForTabs(["genre", "track"], in: window),
            "A double-clicked table keeps its tab, so the next table must get a tab of its own"
        )
        XCTAssertEqual(tabCount(in: window), previewing + 1)

        clickAtCenter(tab("track", in: window))
        clickAtCenter(sidebarRow("note", in: window))
        XCTAssertTrue(
            waitForTabs(["note"], without: ["track"], in: window),
            "Selecting a preview tab must not keep it, so the next table still reuses it"
        )
        XCTAssertEqual(tabCount(in: window), previewing + 1)

        doubleClickAtCenter(tab("note", in: window))
        clickAtCenter(sidebarRow("document", in: window))
        XCTAssertTrue(
            waitForTabs(["note", "document"], in: window),
            "Double-clicking a preview tab keeps it, so the next table must get a tab of its own"
        )
        XCTAssertEqual(tabCount(in: window), previewing + 2)
    }

    private func sidebarRow(_ name: String, in window: XCUIElement) -> XCUIElement {
        let row = objectBrowserRow(name, in: window)
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list \(name)")
        return row
    }

    private func tab(_ title: String, in window: XCUIElement) -> XCUIElement {
        let match = tabs(in: window).matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(match.waitToExist(timeout: 20), "The tab strip must show \(title)")
        return match
    }

    private func tabs(in window: XCUIElement) -> XCUIElementQuery {
        window.descendants(matching: .any).matching(identifier: "editor-tab")
    }

    private func tabCount(in window: XCUIElement) -> Int {
        tabs(in: window).count
    }

    private func hasTab(_ title: String, in window: XCUIElement) -> Bool {
        tabs(in: window).matching(NSPredicate(format: "label == %@", title)).firstMatch.exists
    }

    private func waitForTabs(_ present: [String], without absent: [String] = [], in window: XCUIElement) -> Bool {
        waitForPredicate(timeout: 20) {
            present.allSatisfy { self.hasTab($0, in: window) } && !absent.contains { self.hasTab($0, in: window) }
        }
    }

    private func doubleClickAtCenter(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
    }
}
