import XCTest

/// A preset earns its place in the menu by saving a provider that works: the vendor's Base URL
/// filled in, and Save held back until the key the vendor requires is there. Nothing is typed into
/// the key field, so the sheet never reaches the network.
final class AIProviderPresetUITests: UITestCase {
    func testRequestyPresetFillsItsBaseURLAndWaitsForAKey() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let settingsMenuItem = app.menuBars.menuItems["Settings…"]
        XCTAssertTrue(settingsMenuItem.waitToExist(timeout: 10))
        settingsMenuItem.click()

        let settingsWindow = app.windows["settings"]
        XCTAssertTrue(settingsWindow.waitToExist(timeout: 10))

        let aiPaneButton = app.toolbars.buttons["AI"]
        XCTAssertTrue(aiPaneButton.waitToExist(timeout: 10))
        aiPaneButton.click()

        /// A borderless SwiftUI menu is not reliably a menu button in the accessibility tree, so it
        /// is found by its title whatever element type carries it.
        let addProvider = settingsWindow.descendants(matching: .any)
            .matching(NSPredicate(format: "title == %@ OR label == %@", "Add Provider…", "Add Provider…"))
            .firstMatch
        XCTAssertTrue(addProvider.waitToExist(timeout: 10))
        addProvider.click()

        let requesty = app.menuItems["Requesty"]
        XCTAssertTrue(requesty.waitToExist(timeout: 10))
        requesty.click()

        let sheet = settingsWindow.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 10))

        let baseURL = sheet.textFields["Base URL"]
        XCTAssertTrue(baseURL.waitToExist(timeout: 10))
        XCTAssertEqual(baseURL.value as? String, "https://router.requesty.ai")

        let name = sheet.textFields["Name"]
        XCTAssertTrue(name.waitToExist(timeout: 10))
        XCTAssertEqual(name.value as? String, "Requesty")

        let save = sheet.buttons["Save"]
        XCTAssertTrue(save.waitToExist(timeout: 10))
        XCTAssertFalse(save.isEnabled, "Requesty requires a key, so Save has to wait for one")
    }
}
