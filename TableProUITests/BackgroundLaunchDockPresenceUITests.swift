import AppKit
import XCTest

// A launch the MCP bridge asked for shows nobody anything, so it stays out of the Dock and the app switcher.
final class BackgroundLaunchDockPresenceUITests: UITestCase {
    func testABridgeLaunchStaysHiddenUntilTheAppIsOpened() throws {
        let app = try launchApp(environment: ["TABLEPRO_BACKGROUND_LAUNCH": "1"])

        XCTAssertTrue(
            waitForActivationPolicy(.accessory),
            "A launch the MCP bridge asked for must not put TablePro in the Dock or the app switcher"
        )
        XCTAssertFalse(
            welcomeWindow(in: app).waitToExist(timeout: 5),
            "Nobody asked for a window, so a background launch must not present one"
        )

        // Opened the way Finder does: the reopen event is LaunchServices', and an app with no window
        // and no Dock icon gives XCUIApplication.activate() nothing to act on.
        let opened = expectation(description: "TablePro opened from the Finder")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: builtProductsDirectory.appendingPathComponent("TablePro.app"),
            configuration: configuration
        ) { _, _ in opened.fulfill() }
        wait(for: [opened], timeout: 30)

        XCTAssertTrue(waitForActivationPolicy(.regular), "Opening TablePro must give it back its Dock icon")
        XCTAssertTrue(
            welcomeWindow(in: app).waitToExist(timeout: 10),
            "Opening TablePro with nothing on screen must show the welcome window"
        )
    }
}
