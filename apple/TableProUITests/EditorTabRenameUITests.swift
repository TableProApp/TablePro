import XCTest

// The name field sits in a titlebar accessory, so the double-click, the typing and Return all have to reach it there (#4337).
final class EditorTabRenameUITests: UITestCase {
    func testNamingAQueryTabFromADoubleClickAndFromItsMenu() throws {
        let launch = try launchWithFixture([ConnectionSeed(tabs: [.query("SELECT 1;"), .query("SELECT 2;")])])
        let app = launch.app
        let window = launch.window

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.editorTabTitles(in: window) == ["Query 1", "Query 2"] },
            "The strip must restore both query tabs, got \(editorTabTitles(in: window))"
        )
        let second = editorTabs(titled: "Query 2", in: window).firstMatch
        XCTAssertTrue(waitUntilHittable(second, timeout: 20), "The second tab must be on screen")
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()

        let field = renameField(in: window)
        XCTAssertTrue(field.waitToExist(timeout: 10), "A double-click on a query tab must open its name field")
        field.typeText("Monthly report")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.editorTabTitles(in: window) == ["Query 1", "Monthly report"] },
            "Return must name the tab, got \(editorTabTitles(in: window))"
        )
        XCTAssertTrue(waitForPredicate(timeout: 5) { !field.exists }, "Return must close the name field")

        let first = editorTabs(titled: "Query 1", in: window).firstMatch
        XCTAssertTrue(waitUntilHittable(first, timeout: 20), "The first tab must be on screen")
        first.rightClick()
        let command = contextMenuItem("Rename Tab", in: app)
        XCTAssertTrue(command.waitToExist(timeout: 5), "The tab's menu must offer Rename Tab")
        command.click()

        XCTAssertTrue(field.waitToExist(timeout: 10), "Rename Tab must open the name field")
        field.typeText("Scratch")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.editorTabTitles(in: window) == ["Scratch", "Monthly report"] },
            "Rename Tab must name the tab it was chosen on, got \(editorTabTitles(in: window))"
        )
    }

    private func renameField(in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .textField).matching(identifier: "editor-tab-rename-field").firstMatch
    }
}
