import XCTest

extension UITestCase {
    internal func settingsWindow(in app: XCUIApplication) -> XCUIElement {
        window("settings", in: app)
    }

    internal func openSettings(in app: XCUIApplication) -> XCUIElement {
        app.typeShortcut(.settings)
        let settings = settingsWindow(in: app)
        XCTAssertTrue(settings.waitToExist(timeout: 10), "Cmd+, must open Settings")
        return settings
    }

    internal func settingsSidebarRow(_ pane: String, in settings: XCUIElement) -> XCUIElement {
        settings.descendants(matching: .any).matching(identifier: "settings-sidebar-\(pane)").firstMatch
    }

    // `pane` is the stored pane id (General is "general", Extensions "plugins"); `page` is a page's
    // URL id, such as "software-update", reached through its settings-drill-<page> row.
    internal func selectSettingsPane(_ pane: String, page: String? = nil, in settings: XCUIElement) {
        let row = settingsSidebarRow(pane, in: settings)
        XCTAssertTrue(waitUntilHittable(row, timeout: 10), "The Settings sidebar must list \(pane)")
        row.click()
        guard let page else { return }
        let drill = settings.descendants(matching: .any).matching(identifier: "settings-drill-\(page)").firstMatch
        XCTAssertTrue(scrollUntilHittable(drill, in: settings, timeout: 10), "The \(pane) pane must link to \(page)")
        drill.click()
    }

    internal func settingsPage(_ page: String, in settings: XCUIElement) -> XCUIElement {
        settings.descendants(matching: .any).matching(identifier: "settings-page-\(page)").firstMatch
    }

    // The toolbar's navigation group publishes Back and Forward as buttons with their enabled state.
    internal func settingsNavigationButton(_ label: String, in settings: XCUIElement) -> XCUIElement {
        settings.toolbars.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    internal func attachScreenshot(of element: XCUIElement, named name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
