import XCTest

final class AppearanceSettingsUITests: UITestCase {
    func testCustomThemeFromCreationToDeletion() throws {
        let window = try openAppearancePane()

        createTheme(basedOn: "Dracula", in: window)
        let copy = row("Dracula Copy", in: window)
        XCTAssertTrue(copy.waitToExist(timeout: 10), "The new theme should be listed")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { self.themeDocument(named: "Dracula Copy") != nil },
            "The new theme should be written to the Themes folder"
        )

        rename(selectedThemeTo: "Midnight", in: window)
        XCTAssertTrue(row("Midnight", in: window).waitToExist(timeout: 5), "The list should show the new name")
        XCTAssertFalse(row("Dracula Copy", in: window).exists)

        let dark = window.popUpButtons["appearance-dark-theme"]
        XCTAssertTrue(dark.waitToExist(timeout: 10))
        choose("Midnight", in: dark)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (dark.value as? String) == "Midnight" },
            "A custom dark theme should be offered in the Dark popup"
        )

        clearBackgroundOverride(ofThemeNamed: "Midnight", in: window)

        let midnight = row("Midnight", in: window)
        XCTAssertTrue(waitUntilHittable(midnight, timeout: 10))
        midnight.click()
        let remove = window.buttons["appearance-theme-remove"]
        XCTAssertTrue(remove.waitToExist(timeout: 5))
        XCTAssertEqual(remove.label, "Delete Theme")
        XCTAssertTrue(waitForPredicate(timeout: 5) { remove.isEnabled }, "A selected custom theme can be deleted")
        remove.click()

        let confirmation = window.sheets.firstMatch
        XCTAssertTrue(confirmation.waitToExist(timeout: 5), "Delete should ask first")
        confirmation.buttons["Delete"].click()

        XCTAssertTrue(waitForPredicate(timeout: 5) { !midnight.exists }, "The deleted theme should leave the list")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (dark.value as? String) == "Default Dark" },
            "The slot that held the deleted theme should go back to its built-in"
        )
        XCTAssertNil(themeDocument(named: "Midnight"), "The theme file should be gone")
    }

    // MARK: - Steps

    private func createTheme(basedOn source: String, in window: XCUIElement) {
        let add = element("appearance-theme-add", in: window)
        XCTAssertTrue(waitUntilHittable(add, timeout: 10), "The Custom Themes list should offer its add menu")
        XCTAssertTrue(
            add.label == "Add Theme" || add.title == "Add Theme",
            "The add menu must be named for VoiceOver: got label '\(add.label)', title '\(add.title)'"
        )
        add.click()

        let basedOn = window.menus.firstMatch.menuItems["New Theme Based On"]
        XCTAssertTrue(basedOn.waitToExist(timeout: 5))
        basedOn.hover()
        let item = basedOn.menuItems[source]
        XCTAssertTrue(item.waitToExist(timeout: 5), "New Theme Based On should list \(source)")
        item.click()
    }

    private func rename(selectedThemeTo name: String, in window: XCUIElement) {
        let actions = element("appearance-theme-actions", in: window)
        XCTAssertTrue(waitUntilHittable(actions, timeout: 10))
        XCTAssertTrue(
            actions.label == "Theme Actions" || actions.title == "Theme Actions",
            "The action menu must be named for VoiceOver: got label '\(actions.label)', title '\(actions.title)'"
        )
        actions.click()
        let renameItem = window.menus.firstMatch.menuItems["Rename…"]
        XCTAssertTrue(renameItem.waitToExist(timeout: 5))
        renameItem.click()

        let alert = window.sheets.firstMatch
        XCTAssertTrue(alert.waitToExist(timeout: 5), "Rename should ask for the new name")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(waitUntilHittable(field, timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(name)
        alert.buttons["Rename"].click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { !alert.exists })
    }

    private func clearBackgroundOverride(ofThemeNamed name: String, in window: XCUIElement) {
        let themeRow = row(name, in: window)
        XCTAssertTrue(waitUntilHittable(themeRow, timeout: 10))
        themeRow.doubleClick()

        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 10), "Double-clicking a theme should open its editor")

        let reset = sheet.buttons["theme-color-reset-editor.background"]
        XCTAssertTrue(reset.waitToExist(timeout: 10), "Every color of a Dracula copy starts overridden")
        XCTAssertEqual(reset.label, "Use Default")
        XCTAssertTrue(scrollUntilHittable(reset, in: sheet, timeout: 10))
        reset.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { !reset.exists }, "Use Default should clear the override")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) {
                self.themeDocument(named: name) != nil && self.editorColor("background", ofThemeNamed: name) == nil
            },
            "The cleared override should be saved"
        )

        // The shared color panel cannot be driven reliably; ThemeEditorDraftTests covers what a well hands back.
        let background = element("theme-color-editor.background", in: sheet)
        XCTAssertTrue(waitUntilHittable(background, timeout: 5), "The cleared slot keeps its well")

        let done = sheet.buttons["theme-editor-done"]
        XCTAssertTrue(done.waitToExist(timeout: 5))
        done.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { !sheet.exists }, "Done should close the editor")
        XCTAssertNil(editorColor("background", ofThemeNamed: name), "Closing the editor keeps the last change")
    }

    // MARK: - Helpers

    private func openAppearancePane() throws -> XCUIElement {
        let app = try launchOpeningURL("tablepro://settings/appearance")
        let settings = window("settings", in: app)
        XCTAssertTrue(settings.waitToExist(timeout: 10))
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { settings.title == "Appearance" },
            "The link should open the Appearance pane, the window is titled \(settings.title)"
        )
        return settings
    }

    private func choose(_ title: String, in popup: XCUIElement) {
        XCTAssertTrue(waitUntilHittable(popup, timeout: 10))
        popup.click()
        let item = popup.menuItems[title]
        XCTAssertTrue(item.waitToExist(timeout: 5), "The popup should offer \(title)")
        item.click()
    }

    private func element(_ identifier: String, in container: XCUIElement) -> XCUIElement {
        container.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // SwiftUI text carries its string in `value` with no label, so a subscript by title finds nothing.
    private func row(_ name: String, in window: XCUIElement) -> XCUIElement {
        window.staticTexts.matching(NSPredicate(format: "value == %@", name)).firstMatch
    }

    private func themeDocument(named name: String) -> [String: Any]? {
        guard let root = sandboxRoot else { return nil }
        let directory = root.appendingPathComponent("TablePro/Themes", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["name"] as? String == name
            else { continue }
            return object
        }
        return nil
    }

    private func editorColor(_ key: String, ofThemeNamed name: String) -> String? {
        (themeDocument(named: name)?["editor"] as? [String: Any])?[key] as? String
    }
}
