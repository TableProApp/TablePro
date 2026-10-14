import XCTest

extension UITestCase {
    // MARK: - Editor tabs

    // The strip lays tabs out by position, which is not the order the tree lists them in.
    internal func editorTabs(in window: XCUIElement) -> [XCUIElement] {
        window.descendants(matching: .any)
            .matching(identifier: "editor-tab")
            .allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    internal func editorTabTitles(in window: XCUIElement) -> [String] {
        editorTabs(in: window).map { $0.label }
    }

    internal func editorTab(titled title: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any)
            .matching(identifier: "editor-tab")
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
    }

    internal func selectedEditorTabTitle(in window: XCUIElement) -> String? {
        editorTabs(in: window).first { $0.isSelected }?.label
    }

    internal func selectEditorTab(titled title: String, in window: XCUIElement) {
        let tab = editorTab(titled: title, in: window)
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
