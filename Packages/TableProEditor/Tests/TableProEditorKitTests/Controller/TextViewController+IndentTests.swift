import Foundation
//
//  TextViewController+IndentTests.swift
//  TableProEditorKit
//
//  Created by Ludwig, Tom on 08.10.24.
//

@testable import TableProEditorKit
@testable import TableProTextEngine
import Testing

@MainActor
final class TextViewControllerIndentTests {
    var controller: TextViewController!

    init() throws {
        controller = Mock.textViewController(theme: Mock.theme())

        controller.loadView()
    }

    @Test func testHandleIndentWithSpacesInwards() {
        controller.setText("    This is a test string")
        let cursorPositions = [CursorPosition(range: NSRange(location: 0, length: 0))]
        controller.cursorPositions = cursorPositions
        controller.textView.selectionManager.textSelections = [.init(range: NSRange(location: 0, length: 0))]
        controller.handleIndent(inwards: true)

        #expect(controller.text == "This is a test string")

        // Normally, 4 spaces are used for indentation; however, now we only insert 2 leading spaces.
        // The outcome should be the same, though.
        controller.setText("  This is a test string")
        controller.cursorPositions = cursorPositions
        controller.textView.selectionManager.textSelections = [.init(range: NSRange(location: 0, length: 0))]
        controller.handleIndent(inwards: true)

        #expect(controller.text == "This is a test string")
    }

    @Test func testHandleIndentWithSpacesOutwards() {
        controller.setText("This is a test string")
        let cursorPositions = [CursorPosition(range: NSRange(location: 0, length: 0))]
        controller.textView.selectionManager.textSelections = [.init(range: NSRange(location: 0, length: 0))]
        controller.cursorPositions = cursorPositions

        controller.handleIndent(inwards: false)

        #expect(controller.text == "    This is a test string")
    }

    @Test func testHandleIndentWithTabsInwards() {
        controller.setText("\tThis is a test string")
        controller.configuration.behavior .indentOption = .tab
        let cursorPositions = [CursorPosition(range: NSRange(location: 0, length: 0))]
        controller.textView.selectionManager.textSelections = [.init(range: NSRange(location: 0, length: 0))]
        controller.cursorPositions = cursorPositions

        controller.handleIndent(inwards: true)

        #expect(controller.text == "This is a test string")
    }

    @Test func testHandleIndentWithTabsOutwards() {
        controller.setText("This is a test string")
        controller.configuration.behavior.indentOption = .tab
        let cursorPositions = [CursorPosition(range: NSRange(location: 0, length: 0))]
        controller.textView.selectionManager.textSelections = [.init(range: NSRange(location: 0, length: 0))]
        controller.cursorPositions = cursorPositions

        controller.handleIndent()

        // Normally, we expect nothing to happen because only one line is selected.
        // However, this logic is not handled inside `handleIndent`.
        #expect(controller.text == "\tThis is a test string")
    }

    @Test func testHandleIndentMultiLine() {
        controller.configuration.behavior.indentOption = .tab
        let strings: [(NSString, Int)] = [
            ("This is a test string\n", 0),
            ("With multiple lines\n", 22),
            ("And some indentation", 42),
        ]
        for (insertedString, location) in strings {
            controller.textView.replaceCharacters(
                in: [NSRange(location: location, length: 0)],
                with: insertedString as String
            )
        }

        let cursorPositions = [CursorPosition(range: NSRange(location: 0, length: 62))]
        controller.textView.selectionManager.textSelections = [.init(range: NSRange(location: 0, length: 62))]
        controller.cursorPositions = cursorPositions

        controller.handleIndent()
        let expectedString = "\tThis is a test string\n\tWith multiple lines\n\tAnd some indentation"
        #expect(controller.text == expectedString)
    }

    @Test func testHandleInwardIndentMultiLine() {
        controller.configuration.behavior.indentOption = .tab
        let strings: [(NSString, NSRange)] = [
            ("\tThis is a test string\n", NSRange(location: 0, length: 0)),
            ("\tWith multiple lines\n", NSRange(location: 23, length: 0)),
            ("\tAnd some indentation", NSRange(location: 44, length: 0)),
        ]
        for (insertedString, location) in strings {
            controller.textView.replaceCharacters(
                in: [location],
                with: insertedString as String
            )
        }

        let cursorPositions = [CursorPosition(range: NSRange(location: 0, length: controller.text.count))]
        controller.textView.selectionManager.textSelections = [.init(range: NSRange(location: 0, length: 62))]
        controller.cursorPositions = cursorPositions

        controller.handleIndent(inwards: true)
        let expectedString = "This is a test string\nWith multiple lines\nAnd some indentation"
        #expect(controller.text == expectedString)
    }

    @Test func testMultipleLinesHighlighted() {
        controller.setText("\tThis is a test string\n\tWith multiple lines\n\tAnd some indentation")
        var cursorPositions = [CursorPosition(range: NSRange(location: 0, length: controller.text.count))]
        controller.cursorPositions = cursorPositions

        #expect(controller.multipleLinesHighlighted())

        cursorPositions = [CursorPosition(range: NSRange(location: 0, length: 5))]
        controller.cursorPositions = cursorPositions

        #expect(!controller.multipleLinesHighlighted())
    }
}
