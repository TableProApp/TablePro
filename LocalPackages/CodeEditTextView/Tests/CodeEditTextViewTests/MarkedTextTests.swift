import XCTest
@testable import CodeEditTextView

class MarkedTextTests: XCTestCase {
    func test_markedTextSingleChar() {
        let textView = TextView(string: "")
        textView.selectionManager.setSelectedRange(.zero)

        textView.setMarkedText("´", selectedRange: .notFound, replacementRange: .notFound)
        XCTAssertEqual(textView.string, "´")

        textView.insertText("é", replacementRange: .notFound)
        XCTAssertEqual(textView.string, "é")
        XCTAssertEqual(textView.selectionManager.textSelections.map(\.range), [NSRange(location: 1, length: 0)])
    }

    func test_markedTextSingleCharInStrings() {
        let textView = TextView(string: "Lorem Ipsum")
        textView.selectionManager.setSelectedRange(NSRange(location: 5, length: 0))

        textView.setMarkedText("´", selectedRange: .notFound, replacementRange: .notFound)
        XCTAssertEqual(textView.string, "Lorem´ Ipsum")

        textView.insertText("é", replacementRange: .notFound)
        XCTAssertEqual(textView.string, "Loremé Ipsum")
        XCTAssertEqual(textView.selectionManager.textSelections.map(\.range), [NSRange(location: 6, length: 0)])
    }

    func test_markedTextReplaceSelection() {
        let textView = TextView(string: "ABCDE")
        textView.selectionManager.setSelectedRange(NSRange(location: 4, length: 1))

        textView.setMarkedText("´", selectedRange: .notFound, replacementRange: .notFound)
        XCTAssertEqual(textView.string, "ABCD´")

        textView.insertText("é", replacementRange: .notFound)
        XCTAssertEqual(textView.string, "ABCDé")
        XCTAssertEqual(textView.selectionManager.textSelections.map(\.range), [NSRange(location: 5, length: 0)])
    }

    func test_markedTextMultipleSelection() {
        let textView = TextView(string: "ABC")
        textView.selectionManager.setSelectedRanges([NSRange(location: 1, length: 0), NSRange(location: 2, length: 0)])

        textView.setMarkedText("´", selectedRange: .notFound, replacementRange: .notFound)
        XCTAssertEqual(textView.string, "A´B´C")

        textView.insertText("é", replacementRange: .notFound)
        XCTAssertEqual(textView.string, "AéBéC")
        XCTAssertEqual(
            textView.selectionManager.textSelections.map(\.range).sorted(by: { $0.location < $1.location }),
            [NSRange(location: 2, length: 0), NSRange(location: 4, length: 0)]
        )
    }

    func test_markedTextMultipleSelectionReplaceSelection() {
        let textView = TextView(string: "ABCDE")
        textView.selectionManager.setSelectedRanges([NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)])

        textView.setMarkedText("´", selectedRange: .notFound, replacementRange: .notFound)
        XCTAssertEqual(textView.string, "´BCD´")

        textView.insertText("é", replacementRange: .notFound)
        XCTAssertEqual(textView.string, "éBCDé")
        XCTAssertEqual(
            textView.selectionManager.textSelections.map(\.range).sorted(by: { $0.location < $1.location }),
            [NSRange(location: 1, length: 0), NSRange(location: 5, length: 0)]
        )
    }

    func test_markedTextMultipleSelectionMultipleChar() {
        let textView = TextView(string: "ABCDE")
        textView.selectionManager.setSelectedRanges([NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)])

        textView.setMarkedText("´", selectedRange: .notFound, replacementRange: .notFound)
        XCTAssertEqual(textView.string, "´BCD´")

        textView.setMarkedText("´´´", selectedRange: .notFound, replacementRange: .notFound)
        XCTAssertEqual(textView.string, "´´´BCD´´´")
        XCTAssertEqual(
            textView.selectionManager.textSelections.map(\.range).sorted(by: { $0.location < $1.location }),
            [NSRange(location: 3, length: 0), NSRange(location: 9, length: 0)]
        )

        textView.insertText("é", replacementRange: .notFound)
        XCTAssertEqual(textView.string, "éBCDé")
        XCTAssertEqual(
            textView.selectionManager.textSelections.map(\.range).sorted(by: { $0.location < $1.location }),
            [NSRange(location: 1, length: 0), NSRange(location: 5, length: 0)]
        )
    }

    func test_cancelMarkedText() {
        let textView = TextView(string: "")
        textView.selectionManager.setSelectedRange(.zero)

        textView.setMarkedText("´", selectedRange: .notFound, replacementRange: .notFound)
        XCTAssertEqual(textView.string, "´")

        // The NSTextInputContext performs the following actions when a marked text segment is ended w/o replacing the
        // marked text:
        textView.insertText("´", replacementRange: .notFound)
        textView.insertText("4", replacementRange: .notFound)

        XCTAssertEqual(textView.string, "´4")
        XCTAssertEqual(textView.selectionManager.textSelections.map(\.range), [NSRange(location: 2, length: 0)])
    }

    func test_cancelMarkedTextMultipleCursor() {
        let textView = TextView(string: "ABC")
        textView.selectionManager.setSelectedRanges([NSRange(location: 1, length: 0), NSRange(location: 2, length: 0)])

        textView.setMarkedText("´", selectedRange: .notFound, replacementRange: .notFound)
        XCTAssertEqual(textView.string, "A´B´C")

        // The NSTextInputContext performs the following actions when a marked text segment is ended w/o replacing the
        // marked text:
        textView.insertText("´", replacementRange: .notFound)
        textView.insertText("4", replacementRange: .notFound)

        XCTAssertEqual(textView.string, "A´4B´4C")
        XCTAssertEqual(
            textView.selectionManager.textSelections.map(\.range).sorted(by: { $0.location < $1.location }),
            [NSRange(location: 3, length: 0), NSRange(location: 6, length: 0)]
        )
    }
}
