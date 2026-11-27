import XCTest

final class SyncSettingsUITests: UITestCase {
    // A fresh sandbox is signed out, so neither provider can be chosen yet: each asks for the plan it needs and the
    // picker stays on Off.
    func testProviderPickerOffersEveryProviderAndAsksForAPlanWhenSignedOut() throws {
        let app = try launchOpeningURL("tablepro://settings/sync")

        let settings = settingsWindow(in: app)
        XCTAssertTrue(settings.waitToExist(timeout: 10), "A settings link must open the settings window")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { settings.title == "Sync" },
            "The sync link must open the Sync pane, the window is titled \(settings.title)"
        )

        let picker = settings.popUpButtons["settings-sync-provider"]
        XCTAssertTrue(waitUntilHittable(picker, timeout: 5), "The pane must offer the provider picker")
        XCTAssertEqual(picker.value as? String, "Off", "A new Mac syncs with nothing")
        attachScreenshot(of: settings, named: "settings-sync-off")

        for provider in ["TablePro Sync", "iCloud"] {
            picker.click()
            let item = picker.menuItems[provider]
            XCTAssertTrue(item.waitToExist(timeout: 5), "The picker must offer \(provider)")
            XCTAssertTrue(picker.menuItems["Off"].exists, "The picker must offer Off")
            item.click()

            let alert = settings.children(matching: .sheet).firstMatch
            XCTAssertTrue(alert.waitToExist(timeout: 5), "Choosing \(provider) signed out must ask for a plan")
            XCTAssertTrue(alert.buttons["Cancel"].exists, "The plan sheet must let the person back out")
            alert.buttons["Cancel"].click()
            XCTAssertTrue(waitForPredicate(timeout: 5) { !alert.exists }, "Cancel must close the plan sheet")
            XCTAssertEqual(picker.value as? String, "Off", "Backing out of \(provider) must leave the Mac on Off")
        }
    }
}
