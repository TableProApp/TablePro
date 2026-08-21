import AppKit
import XCTest

/// A TablePro the MCP bridge started answers a client and shows nobody anything, so it has no
/// business in the Dock or the app switcher. LaunchServices reports what the rest of the system
/// sees through `NSRunningApplication.activationPolicy`, which is what these assert on: a window
/// query cannot tell "no Dock icon" from "not in front".
///
/// The app under test is found by its bundle path rather than its identifier, because the developer
/// running this may well have their own TablePro open, and a per-developer
/// `TABLEPRO_APP_BUNDLE_IDENTIFIER` means the identifier is not fixed either.
final class BackgroundLaunchDockPresenceUITests: UITestCase {
    private var builtProductsDirectory: URL {
        Bundle(for: UITestCase.self).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func appUnderTest() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { running in
            guard let bundleURL = running.bundleURL else { return false }
            return bundleURL.lastPathComponent == "TablePro.app"
                && bundleURL.deletingLastPathComponent() == builtProductsDirectory
        }
    }

    private func waitForActivationPolicy(
        _ expected: NSApplication.ActivationPolicy,
        timeout: TimeInterval = 15
    ) -> Bool {
        waitForPredicate(timeout: timeout) { appUnderTest()?.activationPolicy == expected }
    }

    func testABridgeLaunchStaysOutOfTheDock() throws {
        _ = try launchApp(environment: ["TABLEPRO_BACKGROUND_LAUNCH": "1"])

        XCTAssertTrue(
            waitForActivationPolicy(.accessory),
            "A launch the MCP bridge asked for must not put TablePro in the Dock or the app switcher"
        )
    }

    func testABridgeLaunchOpensNoWindow() throws {
        let app = try launchApp(environment: ["TABLEPRO_BACKGROUND_LAUNCH": "1"])

        XCTAssertTrue(waitForActivationPolicy(.accessory))
        XCTAssertFalse(
            app.windows["welcome"].waitForExistence(timeout: 5),
            "Nobody asked for a window, so a background launch must not present one"
        )
    }

    /// Reaching for the app is the gesture that makes the session the person's own, and from then on
    /// it is an ordinary app: a Dock icon, an app switcher entry and a menu bar to quit from.
    ///
    /// Opened the way Finder and Spotlight open it, rather than through `XCUIApplication.activate()`:
    /// the reopen event this turns on is LaunchServices', and an app with no window and no Dock icon
    /// has nothing for the accessibility layer to activate.
    func testOpeningTheAppMakesItAnOrdinaryApp() throws {
        let app = try launchApp(environment: ["TABLEPRO_BACKGROUND_LAUNCH": "1"])
        XCTAssertTrue(waitForActivationPolicy(.accessory))

        let opened = expectation(description: "TablePro opened from the Finder")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: builtProductsDirectory.appendingPathComponent("TablePro.app"),
            configuration: configuration
        ) { _, _ in opened.fulfill() }
        wait(for: [opened], timeout: 30)

        XCTAssertTrue(
            waitForActivationPolicy(.regular),
            "Opening TablePro must give it back its Dock icon"
        )
        XCTAssertTrue(
            app.windows["welcome"].waitForExistence(timeout: 10),
            "Opening TablePro with nothing on screen must show the welcome window"
        )
    }

    func testAnOrdinaryLaunchIsInTheDockFromTheStart() throws {
        let app = try launchApp()

        XCTAssertTrue(app.windows["welcome"].waitForExistence(timeout: 10))
        XCTAssertEqual(
            appUnderTest()?.activationPolicy,
            .regular,
            "A launch the person asked for is an ordinary app"
        )
    }
}
