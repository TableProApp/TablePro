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
    private let databaseIndex = "connection-field-redisDatabase"

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

    /// A server can hold far more than the 16 databases Redis starts with, so the index is typed
    /// as well as stepped, and nothing typed can leave the range a server can be configured for.
    func testDatabaseIndexTakesATypedIndexAndStepsFromIt() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let window = try openRedisConnectionForm(in: app)
        selectConnectionFormTab("options", in: window)

        let control = window.descendants(matching: .any).matching(identifier: databaseIndex).firstMatch
        XCTAssertTrue(control.waitToExist(timeout: 10), "The Options tab should offer a Database Index field")
        let field = control.textFields.firstMatch
        XCTAssertTrue(field.waitToExist(timeout: 5), "The index should be typeable")
        XCTAssertTrue(waitUntilHittable(field, timeout: 10))
        XCTAssertEqual(field.value as? String, "0")

        replaceText(in: field, with: "20a")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (field.value as? String) == "20" },
            "A typed index past 15 should stay, with anything that is not a digit dropped"
        )

        let stepper = control.steppers.firstMatch
        XCTAssertTrue(stepper.waitToExist(timeout: 5), "The field should be paired with a stepper")
        let increment = stepper.incrementArrows.firstMatch
        XCTAssertTrue(waitUntilHittable(increment, timeout: 5))
        increment.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (field.value as? String) == "21" },
            "The stepper should step from the typed index"
        )

        replaceText(in: field, with: "99999999999")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (field.value as? String) == "2147483646" },
            "An index no server can hold should be capped at the highest one a server can"
        )
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
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

        /// Scoped to the sheet, not the window: the chooser is a `.sheet` on the welcome window, so
        /// a window-scoped `searchFields.firstMatch` sees the welcome list's own filter first, and
        /// both carry the identifier `sidebar-filter`. The driver name then goes into the
        /// connection filter and the chooser list is never filtered.
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 10), "New Connection… should open the chooser sheet")

        let search = sheet.searchFields.firstMatch
        XCTAssertTrue(search.waitToExist(timeout: 10), "The chooser should offer its search field")
        XCTAssertTrue(waitUntilHittable(search, timeout: 10))
        search.click()
        search.typeText("Redis")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { (search.value as? String) == "Redis" },
            "Typing should reach the chooser's search field"
        )

        let redis = sheet.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", "Redis"))
            .firstMatch
        XCTAssertTrue(redis.waitToExist(timeout: 10), "The chooser should list Redis")
        XCTAssertTrue(waitUntilHittable(redis, timeout: 10))
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
