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

    internal func gridCell(showing text: String, in grid: XCUIElement) -> XCUIElement {
        grid.staticTexts.matching(NSPredicate(format: "value == %@", text)).firstMatch
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
