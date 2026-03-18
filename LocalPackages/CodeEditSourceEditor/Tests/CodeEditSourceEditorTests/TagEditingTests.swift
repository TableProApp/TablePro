import XCTest
@testable import CodeEditSourceEditor
import SwiftTreeSitter
import AppKit
import SwiftUI

// Tests for ensuring tag auto closing works.

final class TagEditingTests: XCTestCase {
    var controller: TextViewController!
    var theme: EditorTheme!
    var window: NSWindow!

    override func setUpWithError() throws {
        theme = Mock.theme()
        controller = Mock.textViewController(theme: theme)
        let tsClient = Mock.treeSitterClient(forceSync: true)
        controller.treeSitterClient = tsClient
        controller.highlightProviders = [tsClient]
        window = NSWindow()
        window.contentViewController = controller
        controller.loadView()
        window.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 1000), display: false)
    }

    func test_tagClose() {
        controller.setText("<!doctype html><html><div></html>")
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 26, length: 0))
        controller.textView.insertText(" ")
        XCTAssertEqual(controller.textView.string, "<!doctype html><html><div> </div></html>")

        controller.setText("<!doctype html><html><h1></html>")
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 25, length: 0))
        controller.textView.insertText("Header")
        XCTAssertEqual(controller.textView.string, "<!doctype html><html><h1>Header</h1></html>")

        controller.setText("<!doctype html><html><veryLongClassName></html>")
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 40, length: 0))
        controller.textView.insertText("hello world!")
        XCTAssertEqual(
            controller.textView.string,
            "<!doctype html><html><veryLongClassName>hello world!</veryLongClassName></html>"
        )
    }

    func test_tagCloseWithNewline() {
        controller.configuration.behavior.indentOption = .spaces(count: 4)

        controller.setText("<!doctype html>\n<div>")
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 21, length: 0))
        controller.textView.insertNewline(nil)
        XCTAssertEqual(controller.textView.string, "<!doctype html>\n<div>\n    \n</div>")

        controller.setText("<!doctype html>\n    <div>\n")
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 25, length: 0))
        controller.textView.insertNewline(nil)
        XCTAssertEqual(controller.textView.string, "<!doctype html>\n    <div>\n        \n    </div>\n")
    }

    func test_nestedClose() {
        controller.configuration.behavior.indentOption = .spaces(count: 4)

        controller.setText("<html>\n    <div>\n        <div>\n    </div>\n</html>")
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 30, length: 0))
        controller.textView.insertNewline(nil)
        XCTAssertEqual(
            controller.textView.string,
            "<html>\n    <div>\n        <div>\n            \n        </div>\n    </div>\n</html>"
        )
        XCTAssertEqual(
            controller.cursorPositions[0],
            CursorPosition(range: NSRange(location: 43, length: 0), start: .init(line: 4, column: 13), end: nil)
        )
    }

    func test_tagNotClose() {
        controller.configuration.behavior.indentOption = .spaces(count: 1)

        controller.setText("<html>\n <div>\n  <div>\n </div>\n</html>")
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 6, length: 0))
        controller.textView.insertNewline(nil)
        XCTAssertEqual(
            controller.textView.string,
            "<html>\n\n <div>\n  <div>\n </div>\n</html>"
        )
        XCTAssertEqual(
            controller.cursorPositions[0],
            CursorPosition(range: NSRange(location: 7, length: 0), start: .init(line: 2, column: 1), end: nil)
        )
    }

    func test_tagCloseWithAttributes() {
        controller.setText("<html><h1 class=\"color:blue\"></html>")
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 29, length: 0))
        controller.textView.insertText(" ")
        XCTAssertEqual(controller.textView.string, "<html><h1 class=\"color:blue\"> </h1></html>")
    }

    func test_JSXTagClose() {
        controller.language = .jsx
        controller.setText("""
        const name = "CodeEdit"
        const element = (
            <h1>
                Hello {name}!
                <p>
            </h1>
        );
        """)
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 84, length: 0))
        controller.textView.insertText(" ")
        // swifltint:disable:next trailing_whitespace
        XCTAssertEqual(
            controller.textView.string,
            """
            const name = "CodeEdit"
            const element = (
                <h1>
                    Hello {name}!
                    <p> </p>
                </h1>
            );
            """
        )
        // swiflint:enable trailing_whitespace
    }

    func test_TSXTagClose() {
        controller.language = .tsx
        controller.configuration.behavior.indentOption = .spaces(count: 4)
        controller.setText("""
        const name = "CodeEdit"
        const element = (
            <h1>
                Hello {name}!
                <p>
            </h1>
        );
        """)
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 84, length: 0))
        controller.textView.insertText(" ")
        // swifltint:disable:next trailing_whitespace
        XCTAssertEqual(
            controller.textView.string,
            """
            const name = "CodeEdit"
            const element = (
                <h1>
                    Hello {name}!
                    <p> </p>
                </h1>
            );
            """
        )
        // swiflint:enable trailing_whitespace
    }
}
