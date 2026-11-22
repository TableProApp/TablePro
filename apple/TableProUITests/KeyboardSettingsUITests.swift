import XCTest

final class KeyboardSettingsUITests: UITestCase {
    // One launch: filter from the toolbar, cancel, record, then restore every default.
    func testFilterRecordAndRestoreDefaults() throws {
        let app = try launchApp()
        let settings = openSettings(in: app)
        selectSettingsPane("keyboard", in: settings)
        XCTAssertTrue(waitForPredicate(timeout: 5) { settings.title == "Keyboard" }, "Picking Keyboard must title the window")

        app.typeShortcut(.find)
        let search = settings.searchFields.matching(identifier: "shortcut-search").firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { self.holdsKeyboardFocus(search) },
            "Cmd-F on Keyboard must focus the toolbar filter"
        )
        search.typeText("Refresh")

        let refresh = settings.buttons.matching(identifier: "shortcut-recorder-refresh").firstMatch
        let executeQuery = settings.buttons.matching(identifier: "shortcut-recorder-executeQuery").firstMatch
        XCTAssertTrue(waitUntilHittable(refresh, timeout: 5), "The filter must keep the Refresh row")
        XCTAssertTrue(waitForPredicate(timeout: 5) { !executeQuery.exists }, "The filter must drop rows that do not match")
        XCTAssertEqual(refresh.title, "⌘R")

        refresh.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { refresh.title == "Type Shortcut" }, "A click must arm the recorder")
        attachScreenshot(of: settings, named: "settings-keyboard-armed")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForPredicate(timeout: 5) { refresh.title == "⌘R" }, "Escape must cancel and keep the key")

        refresh.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { refresh.title == "Type Shortcut" })
        app.typeKey("j", modifierFlags: [.command, .option, .control])
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { refresh.title == "⌃⌥⌘J" },
            "A free chord must be recorded, the recorder shows \(refresh.title)"
        )
        XCTAssertTrue(settings.buttons["shortcut-reset-refresh"].exists, "A customized row offers its reset button")

        let restore = settings.buttons["shortcut-restore-defaults"]
        XCTAssertTrue(waitForPredicate(timeout: 5) { restore.isEnabled }, "A customized shortcut enables Restore Defaults")
        restore.click()
        let confirmation = settings.sheets.firstMatch
        XCTAssertTrue(confirmation.waitToExist(timeout: 5), "Restore Defaults must ask first")
        confirmation.buttons["Restore Defaults"].click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { refresh.title == "⌘R" }, "Restoring must bring the default back")
        XCTAssertTrue(waitForPredicate(timeout: 5) { !restore.isEnabled }, "Nothing is left to restore")
    }
}
