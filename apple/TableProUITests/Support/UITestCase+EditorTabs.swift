import XCTest

extension UITestCase {
    // MARK: - Editor tabs

    internal func editorTabs(titled title: String? = nil, in window: XCUIElement) -> XCUIElementQuery {
        let tabs = window.descendants(matching: .any).matching(identifier: "editor-tab")
        guard let title else { return tabs }
        return tabs.matching(NSPredicate(format: "label == %@", title))
    }

    // The strip lays tabs out by position, which is not the order the tree lists them in.
    internal func editorTabTitles(in window: XCUIElement) -> [String] {
        editorTabs(in: window).allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { $0.label }
    }

    internal func selectedEditorTabTitle(in window: XCUIElement) -> String? {
        editorTabs(in: window).allElementsBoundByIndex.first { $0.isSelected }?.label
    }

    internal func selectEditorTab(titled title: String, in window: XCUIElement) {
        let tab = editorTabs(titled: title, in: window).firstMatch
        XCTAssertTrue(waitUntilHittable(tab, timeout: 20), "The \(title) tab must be on screen")
        clickAtCenter(tab)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.selectedEditorTabTitle(in: window) == title },
            "Clicking the \(title) tab must select it"
        )
    }

    // MARK: - Results

    internal func resultSetChooser(in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: "result-set-menu").firstMatch
    }

    internal func resultSetTabs(in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: "result-set-tabs").firstMatch
    }

    // A tab is a `Tab` element under the tabs role on macOS 27 and a radio button before it, like a view switcher's.
    internal func resultSetTab(containing text: String, in tabs: XCUIElement) -> XCUIElement {
        let types = [XCUIElement.ElementType.tab, .radioButton].map(\.rawValue)
        return tabs.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ AND elementType IN %@", text, types))
            .firstMatch
    }

    internal func gridCell(showing text: String, in grid: XCUIElement) -> XCUIElement {
        grid.staticTexts.matching(NSPredicate(format: "value == %@", text)).firstMatch
    }

    // MARK: - Key bindings

    // Picks a key bindings mode in Settings > Editor and closes Settings. A new sandbox starts on Standard.
    internal func chooseKeyBindings(_ title: String, in app: XCUIApplication) {
        app.typeShortcut(.settings)
        let settings = window("settings", in: app)
        XCTAssertTrue(settings.waitToExist(timeout: 10), "Cmd+, must open Settings")
        let editorPane = settings.toolbars.buttons["Editor"]
        XCTAssertTrue(editorPane.waitToExist(timeout: 10))
        editorPane.click()

        let keyBindings = settings.popUpButtons["key-bindings-picker"]
        XCTAssertTrue(scrollUntilHittable(keyBindings, in: settings, timeout: 30), "The Editor pane must offer key bindings")
        XCTAssertEqual(keyBindings.value as? String, "Standard", "A new sandbox starts with the standard key bindings")
        keyBindings.click()
        let item = keyBindings.menuItems[title]
        XCTAssertTrue(item.waitToExist(timeout: 5), "The key bindings popup must offer \(title)")
        item.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (keyBindings.value as? String) == title },
            "\(title) key bindings must be chosen after the click"
        )

        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 10), "Settings must close")
    }

    // MARK: - Editor text

    internal func editorText(_ editor: XCUIElement) -> String {
        (editor.value as? String) ?? ""
    }

    internal func waitForEditorText(
        _ editor: XCUIElement,
        timeout: TimeInterval = 10,
        _ matches: (String) -> Bool
    ) -> Bool {
        waitForPredicate(timeout: timeout) { matches(self.editorText(editor)) }
    }
}
