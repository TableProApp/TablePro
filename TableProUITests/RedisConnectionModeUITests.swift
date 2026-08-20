import XCTest

/// The Redis connection form swaps whole groups of fields when the mode changes, and the fields it
/// swaps live in two different panes. Nothing below the view models proves the swap actually
/// reaches the screen, so this drives the real form.
final class RedisConnectionModeUITests: UITestCase {
    func testSwitchingConnectionModeShowsOnlyThatModesFields() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        try openRedisConnectionForm(in: app)

        let window = app.windows.firstMatch
        let modePicker = window.popUpButtons["Connection Mode"]
        XCTAssertTrue(
            modePicker.waitForExistence(timeout: 10),
            "The Redis form should offer a Connection Mode picker"
        )

        XCTAssertTrue(window.textFields["Host"].exists, "Standalone shows Host and Port")
        XCTAssertFalse(window.staticTexts["Sentinel Nodes"].exists)
        XCTAssertFalse(window.staticTexts["Cluster Seed Nodes"].exists)

        select(option: "Sentinel", in: modePicker)
        XCTAssertTrue(
            window.staticTexts["Sentinel Nodes"].waitForExistence(timeout: 5),
            "Sentinel mode replaces Host and Port with the Sentinel node list"
        )
        XCTAssertTrue(window.textFields["Primary Group Name"].waitForExistence(timeout: 5))
        XCTAssertFalse(window.staticTexts["Cluster Seed Nodes"].exists)
        XCTAssertFalse(window.textFields["Host"].exists)

        select(option: "Cluster", in: modePicker)
        XCTAssertTrue(
            window.staticTexts["Cluster Seed Nodes"].waitForExistence(timeout: 5),
            "Cluster mode shows its own seed node list"
        )
        XCTAssertFalse(window.staticTexts["Sentinel Nodes"].exists)
        XCTAssertFalse(window.textFields["Primary Group Name"].exists)

        select(option: "Standalone", in: modePicker)
        XCTAssertTrue(
            window.textFields["Host"].waitForExistence(timeout: 5),
            "Going back to Standalone restores Host and Port"
        )
        XCTAssertFalse(window.staticTexts["Sentinel Nodes"].exists)
        XCTAssertFalse(window.staticTexts["Cluster Seed Nodes"].exists)
    }

    private func openRedisConnectionForm(in app: XCUIApplication) throws {
        let newConnection = app.menuBars.menuItems["New Connection..."]
        XCTAssertTrue(newConnection.waitForExistence(timeout: 10))
        newConnection.click()

        let redis = app.windows.firstMatch.buttons["Redis"]
        XCTAssertTrue(redis.waitForExistence(timeout: 10), "The chooser should list Redis")
        waitUntilHittable(redis)
        redis.click()
    }

    private func select(option: String, in picker: XCUIElement) {
        waitUntilHittable(picker)
        picker.click()
        let item = picker.menuItems[option]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "The mode picker should offer \(option)")
        item.click()
    }

    private func waitUntilHittable(_ element: XCUIElement) {
        let hittable = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: hittable, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed)
    }
}
