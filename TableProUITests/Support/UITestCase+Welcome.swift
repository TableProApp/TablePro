import AppKit
import XCTest

extension UITestCase {
    internal var builtProductsDirectory: URL {
        Bundle(for: UITestCase.self).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // Matched by bundle path: the developer's own TablePro may be running, and the bundle identifier is per developer.
    internal func appUnderTest() -> NSRunningApplication? {
        let products = builtProductsDirectory
        return NSWorkspace.shared.runningApplications.first { running in
            guard let bundleURL = running.bundleURL else { return false }
            return bundleURL.lastPathComponent == "TablePro.app"
                && bundleURL.deletingLastPathComponent() == products
        }
    }

    // LaunchServices' policy is what the Dock and the app switcher read; a window query cannot tell
    // "no Dock icon" from "not in front".
    internal func waitForActivationPolicy(
        _ expected: NSApplication.ActivationPolicy,
        timeout: TimeInterval = 15
    ) -> Bool {
        waitForPredicate(timeout: timeout) { self.appUnderTest()?.activationPolicy == expected }
    }

    internal func welcomeConnectionList(in welcome: XCUIElement) -> XCUIElement {
        welcome.outlines["welcome-connection-list"]
    }

    // A row publishes its name either as its label or as a static text's value, depending on the cell.
    internal func welcomeConnectionRows(named name: String, in list: XCUIElement) -> XCUIElementQuery {
        list.outlineRows.containing(
            NSPredicate(
                format: "label BEGINSWITH %@ OR (elementType == %lu AND value BEGINSWITH %@)",
                name,
                XCUIElement.ElementType.staticText.rawValue,
                name
            )
        )
    }

    internal func welcomeConnectionRow(named name: String, in list: XCUIElement) -> XCUIElement {
        welcomeConnectionRows(named: name, in: list).firstMatch
    }
}
