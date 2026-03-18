//
//  TextViewController+MoveLinesTests.swift
//  CodeEditSourceEditor
//
//  Created by Bogdan Belogurov on 01/06/2025.
//

import XCTest
@testable import CodeEditSourceEditor
@testable import CodeEditTextView
import CustomDump

final class TextViewControllerMoveLinesTests: XCTestCase {
    var controller: TextViewController!

    override func setUpWithError() throws {
        controller = Mock.textViewController(theme: Mock.theme())

        controller.loadView()
    }

    func testHandleMoveLinesUpForSingleLine() {
        let strings: [(NSString, Int)] = [
            ("This is a test string\n", 0),
            ("With multiple lines\n", 22)
        ]
        for (insertedString, location) in strings {
            controller.textView.replaceCharacters(
                in: [NSRange(location: location, length: 0)],
                with: insertedString as String
            )
        }

        let cursorRange = NSRange(location: 40, length: 0)
        controller.textView.selectionManager.textSelections = [.init(range: cursorRange)]
        controller.cursorPositions = [CursorPosition(range: cursorRange)]

        controller.moveLinesUp()
        let expectedString = "With multiple lines\nThis is a test string\n"
        expectNoDifference(controller.text, expectedString)
    }

    func testHandleMoveLinesDownForSingleLine() {
        let strings: [(NSString, Int)] = [
            ("This is a test string\n", 0),
            ("With multiple lines\n", 22)
        ]
        for (insertedString, location) in strings {
            controller.textView.replaceCharacters(
                in: [NSRange(location: location, length: 0)],
                with: insertedString as String
            )
        }

        let cursorRange = NSRange(location: 0, length: 0)
        controller.textView.selectionManager.textSelections = [.init(range: cursorRange)]
        controller.cursorPositions = [CursorPosition(range: cursorRange)]

        controller.moveLinesDown()
        let expectedString = "With multiple lines\nThis is a test string\n"
        expectNoDifference(controller.text, expectedString)
    }

    func testHandleMoveLinesUpForMultiLine() {
        let strings: [(NSString, Int)] = [
            ("This is a test string\n", 0),
            ("With multiple lines\n", 22),
            ("And additional info\n", 42)
        ]
        for (insertedString, location) in strings {
            controller.textView.replaceCharacters(
                in: [NSRange(location: location, length: 0)],
                with: insertedString as String
            )
        }

        let cursorRange = NSRange(location: 40, length: 15)
        controller.textView.selectionManager.textSelections = [.init(range: cursorRange)]
        controller.cursorPositions = [CursorPosition(range: cursorRange)]

        controller.moveLinesUp()
        let expectedString = "With multiple lines\nAnd additional info\nThis is a test string\n"
        expectNoDifference(controller.text, expectedString)
    }

    func testHandleMoveLinesDownForMultiLine() {
        let strings: [(NSString, Int)] = [
            ("This is a test string\n", 0),
            ("With multiple lines\n", 22),
            ("And additional info\n", 42)
        ]
        for (insertedString, location) in strings {
            controller.textView.replaceCharacters(
                in: [NSRange(location: location, length: 0)],
                with: insertedString as String
            )
        }

        let cursorRange = NSRange(location: 0, length: 30)
        controller.textView.selectionManager.textSelections = [.init(range: cursorRange)]
        controller.cursorPositions = [CursorPosition(range: cursorRange)]

        controller.moveLinesDown()
        let expectedString = "And additional info\nThis is a test string\nWith multiple lines\n"
        expectNoDifference(controller.text, expectedString)
    }
}
