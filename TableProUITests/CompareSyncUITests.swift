import XCTest

final class CompareSyncUITests: UITestCase {
    private func launchAndOpenCompareSync() throws -> XCUIApplication {
        let app = try launchApp()

        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitForExistence(timeout: 10))
        menuBar.menuBarItems["Database"].click()
        menuBar.menuItems["Compare"].click()

        let item = menuBar.menuItems["Compare & Sync Databases…"]
        XCTAssertTrue(
            item.waitForExistence(timeout: 5),
            "Compare & Sync must be reachable from Database > Compare"
        )
        guard item.isEnabled else {
            throw XCTSkip("Compare & Sync is licence gated and unavailable in this build")
        }
        item.click()
        return app
    }

    private func compareWindow(in app: XCUIApplication) -> XCUIElement {
        app.windows["Compare & Sync"]
    }

    func testCompareSyncOpensFromFileMenu() throws {
        let app = try launchAndOpenCompareSync()

        XCTAssertTrue(
            compareWindow(in: app).waitForExistence(timeout: 10),
            "Choosing the menu item must open the Compare & Sync window"
        )
    }

    func testBannerStatesNothingHasBeenWrittenBeforeAnyRun() throws {
        let app = try launchAndOpenCompareSync()
        let window = compareWindow(in: app)
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let banner = window.staticTexts["Comparing only. Nothing has been written."]
        XCTAssertTrue(
            banner.waitForExistence(timeout: 5),
            "The window must say nothing has been written until the user applies"
        )
    }

    func testCompareIsDisabledUntilBothEndpointsAreChosen() throws {
        let app = try launchAndOpenCompareSync()
        let window = compareWindow(in: app)
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let compareButton = window.buttons["Compare"]
        XCTAssertTrue(compareButton.waitForExistence(timeout: 5))
        XCTAssertFalse(
            compareButton.isEnabled,
            "Compare must stay disabled while no target is chosen, so the write side is always deliberate"
        )
    }

    func testTargetPickerStartsWithNoConnectionChosen() throws {
        let app = try launchAndOpenCompareSync()
        let window = compareWindow(in: app)
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let placeholders = window.popUpButtons.matching(
            NSPredicate(format: "value == %@", "Choose a connection")
        )
        XCTAssertGreaterThanOrEqual(
            placeholders.count, 2,
            "Neither source nor target may be preselected"
        )
    }

    func testSwapIsDisabledWhenNoEndpointIsChosen() throws {
        let app = try launchAndOpenCompareSync()
        let window = compareWindow(in: app)
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let swap = window.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Swap")
        ).firstMatch
        guard swap.waitForExistence(timeout: 5) else {
            throw XCTSkip("Swap control not exposed to accessibility in this build")
        }
        XCTAssertFalse(swap.isEnabled, "Swap has nothing to swap before an endpoint is chosen")
    }
}
