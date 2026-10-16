import XCTest

final class AppearanceSettingsUITests: UITestCase {
    func testCustomThemeFromCreationToTrashAndBack() throws {
        let app = try launchOpeningURL("tablepro://settings/appearance")
        let settings = try appearancePane(in: app)

        createTheme(basedOn: "Dracula", in: settings)
        let editor = window("theme-editor", in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10), "New Theme Based On should open the Theme Editor")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { editor.title == "Dracula Copy" },
            "The editor window is titled with the theme's name, got \(editor.title)"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { self.themeDocument(named: "Dracula Copy") != nil },
            "The new theme should be written to the Themes folder"
        )

        resetAndUndoEditorBackground(in: editor, app: app, themeName: "Dracula Copy")

        editor.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { !editor.exists }, "The close button should close the editor")
        XCTAssertNotNil(editorColor("background", ofThemeNamed: "Dracula Copy"), "Closing keeps the undone color")

        renameInRow("Dracula Copy", to: "Midnight", in: settings)

        let dark = settings.popUpButtons["appearance-dark-theme"]
        XCTAssertTrue(dark.waitToExist(timeout: 10))
        choose("Midnight", in: dark)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (dark.value as? String) == "Midnight" },
            "A custom dark theme should be offered in the Dark popup"
        )

        moveToTrash("Midnight", in: settings)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (dark.value as? String) == "Default Dark" },
            "The slot that held the trashed theme should go back to its built-in"
        )
        XCTAssertNil(themeDocument(named: "Midnight"), "The theme file should leave the Themes folder")

        app.typeShortcut(.undo)
        XCTAssertTrue(row("Midnight", in: settings).waitToExist(timeout: 5), "Undo should bring the theme back")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { self.themeDocument(named: "Midnight") != nil },
            "Undo should put the file back in the Themes folder"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (dark.value as? String) == "Midnight" },
            "Undo should give the Dark slot its theme back"
        )
    }

    func testThemesListScrollsAndTakesArrowKeys() throws {
        let app = try launchOpeningURL("tablepro://settings/appearance")
        let settings = try appearancePane(in: app)
        let list = settings.outlines.containing(NSPredicate(format: "value == %@", "Default Light")).firstMatch
        XCTAssertTrue(list.waitToExist(timeout: 10), "The Themes list should be on the Appearance pane")
        // The bar under the list marks where its visible rows end; an outline's own frame spans every row.
        let footer = element("appearance-theme-add", in: settings)
        XCTAssertTrue(footer.waitToExist(timeout: 10))

        let last = row("Tokyo Night Light", in: list)
        XCTAssertTrue(last.waitToExist(timeout: 10))
        let deadline = Date(timeIntervalSinceNow: 10)
        while last.frame.maxY > footer.frame.minY, Date() < deadline {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).scroll(byDeltaX: 0, deltaY: -60)
        }
        XCTAssertLessThanOrEqual(last.frame.maxY, footer.frame.minY, "A scroll over the list should bring its last theme into view")

        let previous = outlineRow("Tokyo Night", in: list)
        let next = outlineRow("Tokyo Night Light", in: list)
        XCTAssertTrue(waitUntilHittable(previous, timeout: 5), "Tokyo Night should be visible above the last row")
        previous.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { previous.isSelected }, "A click should select the theme")
        settings.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { next.isSelected && !previous.isSelected },
            "Down Arrow should move the selection, so the click must have given the list keyboard focus"
        )
    }

    // MARK: - Steps

    private func createTheme(basedOn source: String, in window: XCUIElement) {
        let add = element("appearance-theme-add", in: window)
        XCTAssertTrue(add.waitToExist(timeout: 10), "The Themes list should offer its add menu")
        XCTAssertTrue(waitUntilHittable(add, timeout: 10), "The Themes list should offer its add menu")
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

    /// The shared color panel cannot be driven reliably; ThemeEditorModelTests covers what a well hands back.
    private func resetAndUndoEditorBackground(in editor: XCUIElement, app: XCUIApplication, themeName: String) {
        let reset = element("theme-color-reset-editor.background", in: editor)
        XCTAssertTrue(reset.waitToExist(timeout: 10), "A Dracula copy sets the editor background")
        XCTAssertEqual(reset.label, "Use System Color for Editor Background")
        let slots = element("theme-editor-slots", in: editor)
        XCTAssertTrue(slots.waitToExist(timeout: 5))
        reveal(reset, in: slots, scrollingAt: CGVector(dx: 0.5, dy: 0.5))
        reset.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { !reset.exists }, "Use System Color should clear the slot")
        let state = element("theme-color-state-editor.background", in: editor)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (state.value as? String) == "System color" },
            "The row should say the slot follows the system"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { self.editorColor("background", ofThemeNamed: themeName) == nil },
            "The cleared slot should be saved"
        )

        app.typeShortcut(.undo)
        XCTAssertTrue(reset.waitToExist(timeout: 5), "Undo should put the color back")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { self.editorColor("background", ofThemeNamed: themeName) != nil },
            "The undone change should be saved"
        )
    }

    private func renameInRow(_ name: String, to newName: String, in window: XCUIElement) {
        let themeRow = row(name, in: window)
        XCTAssertTrue(waitUntilHittable(themeRow, timeout: 10))
        themeRow.click()

        let actions = element("appearance-theme-actions", in: window)
        XCTAssertTrue(actions.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntilHittable(actions, timeout: 10))
        XCTAssertTrue(
            actions.label == "Theme Actions" || actions.title == "Theme Actions",
            "The action menu must be named for VoiceOver: got label '\(actions.label)', title '\(actions.title)'"
        )
        actions.click()
        let renameItem = window.menus.firstMatch.menuItems["Rename"]
        XCTAssertTrue(renameItem.waitToExist(timeout: 5))
        renameItem.click()

        let field = element("appearance-theme-rename-field", in: window)
        XCTAssertTrue(waitUntilHittable(field, timeout: 5), "Rename should edit the name in its row")
        field.typeKey("a", modifierFlags: .command)
        field.typeText(newName + "\r")
        XCTAssertTrue(waitForPredicate(timeout: 5) { !field.exists }, "Return should end the rename")
        XCTAssertTrue(row(newName, in: window).waitToExist(timeout: 5), "The list should show the new name")
        XCTAssertFalse(row(name, in: window).exists)
    }

    private func moveToTrash(_ name: String, in window: XCUIElement) {
        let themeRow = row(name, in: window)
        XCTAssertTrue(waitUntilHittable(themeRow, timeout: 10))
        themeRow.click()
        let remove = window.buttons["appearance-theme-remove"]
        XCTAssertTrue(remove.waitToExist(timeout: 5))
        XCTAssertEqual(remove.label, "Move to Trash")
        XCTAssertTrue(waitForPredicate(timeout: 5) { remove.isEnabled }, "A selected custom theme can be trashed")
        remove.click()

        let confirmation = window.sheets.firstMatch
        XCTAssertTrue(confirmation.waitToExist(timeout: 5), "Trashing the theme a slot uses should ask first")
        confirmation.buttons["Move to Trash"].click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { !themeRow.exists }, "The trashed theme should leave the list")
    }

    // MARK: - Helpers

    private func appearancePane(in app: XCUIApplication) throws -> XCUIElement {
        let settings = window("settings", in: app)
        XCTAssertTrue(settings.waitToExist(timeout: 10))
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { settings.title == "Appearance" },
            "The link should open the Appearance pane, the window is titled \(settings.title)"
        )
        return settings
    }

    /// A control clipped by its scroll view still reads as hittable, and a click on it lands on
    /// whatever is drawn there, so the frames decide when it is in view.
    private func reveal(_ control: XCUIElement, in scrollView: XCUIElement, scrollingAt point: CGVector) {
        let deadline = Date(timeIntervalSinceNow: 10)
        while control.frame.maxY > scrollView.frame.maxY || control.frame.minY < scrollView.frame.minY, Date() < deadline {
            let overshoot = control.frame.maxY > scrollView.frame.maxY
                ? scrollView.frame.maxY - control.frame.maxY - 20
                : scrollView.frame.minY - control.frame.minY + 20
            scrollView.coordinate(withNormalizedOffset: point).scroll(byDeltaX: 0, deltaY: overshoot)
        }
        XCTAssertTrue(
            control.frame.minY >= scrollView.frame.minY && control.frame.maxY <= scrollView.frame.maxY,
            "\(control.identifier) should scroll into view"
        )
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

    private func outlineRow(_ name: String, in list: XCUIElement) -> XCUIElement {
        list.outlineRows.containing(NSPredicate(format: "value == %@", name)).firstMatch
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
