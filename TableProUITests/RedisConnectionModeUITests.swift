import XCTest

/// The Redis connection form swaps whole groups of fields when the mode changes, and the fields it
/// swaps live in two different panes. Nothing below the view models proves the swap actually
/// reaches the screen, so this drives the real form.
///
/// Every element here is reached by accessibility identifier. The form renders plugin fields as
/// hosted SwiftUI controls, which arrive with their text in `value` and no label of their own, so
/// a query by visible title matches nothing at all.
final class RedisConnectionModeUITests: UITestCase {
    private let modePicker = "connection-field-redisMode"
    private let sentinelNodes = "connection-field-redisSentinelHosts"
    private let sentinelGroupName = "connection-field-redisSentinelMasterName"
    private let clusterNodes = "connection-field-redisClusterHosts"

    func testSwitchingConnectionModeShowsOnlyThatModesFields() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let window = try openRedisConnectionForm(in: app)
        let picker = window.popUpButtons[modePicker]
        XCTAssertTrue(
            picker.waitToExist(timeout: 10),
            "The Redis form should offer a Connection Mode picker"
        )

        XCTAssertTrue(window.textFields["connection-form-host"].exists, "Standalone shows Host and Port")
        XCTAssertFalse(hasField(sentinelNodes, in: window))
        XCTAssertFalse(hasField(clusterNodes, in: window))

        select(option: "Sentinel", in: picker)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { hasField(sentinelNodes, in: window) },
            "Sentinel mode replaces Host and Port with the Sentinel node list"
        )
        XCTAssertTrue(window.textFields[sentinelGroupName].waitToExist(timeout: 5))
        XCTAssertFalse(hasField(clusterNodes, in: window))
        XCTAssertFalse(window.textFields["connection-form-host"].exists)

        select(option: "Cluster", in: picker)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { hasField(clusterNodes, in: window) },
            "Cluster mode shows its own seed node list"
        )
        XCTAssertFalse(hasField(sentinelNodes, in: window))
        XCTAssertFalse(window.textFields[sentinelGroupName].exists)

        select(option: "Standalone", in: picker)
        XCTAssertTrue(
            window.textFields["connection-form-host"].waitToExist(timeout: 5),
            "Going back to Standalone restores Host and Port"
        )
        XCTAssertFalse(hasField(sentinelNodes, in: window))
        XCTAssertFalse(hasField(clusterNodes, in: window))
    }

    /// A host list is a whole subtree rather than one control, so its identifier lands on every
    /// element inside it and any one of them proves the list is on screen.
    private func hasField(_ identifier: String, in window: XCUIElement) -> Bool {
        window.descendants(matching: .any).matching(identifier: identifier).count > 0
    }

    private func openRedisConnectionForm(in app: XCUIApplication) throws -> XCUIElement {
        let newConnection = app.menuBars.menuItems["New Connection…"]
        XCTAssertTrue(newConnection.waitToExist(timeout: 10))
        newConnection.click()

        let chooser = app.windows.firstMatch
        let search = chooser.searchFields.firstMatch
        XCTAssertTrue(search.waitToExist(timeout: 10), "The chooser should offer its search field")
        search.click()
        app.typeText("Redis")

        let redis = chooser.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", "Redis"))
            .firstMatch
        XCTAssertTrue(redis.waitToExist(timeout: 10), "The chooser should list Redis")
        redis.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()

        let form = app.windows["connection-form"]
        XCTAssertTrue(form.waitToExist(timeout: 10), "Choosing Redis should open the connection form")
        return form
    }

    private func select(option: String, in picker: XCUIElement) {
        XCTAssertTrue(waitUntilHittable(picker, timeout: 10))
        picker.click()
        let item = picker.menuItems[option]
        XCTAssertTrue(item.waitToExist(timeout: 5), "The mode picker should offer \(option)")
        item.click()
    }
}
