import XCTest
@testable import CodeEditTextView

final class TextSelectionManagerTests: XCTestCase {
    var textStorage: NSTextStorage!
    var layoutManager: TextLayoutManager!

    func selectionManager(_ text: String = "Loren Ipsum 💯") -> TextSelectionManager {
        textStorage = NSTextStorage(string: text)
        layoutManager = TextLayoutManager(
            textStorage: textStorage,
            lineHeightMultiplier: 1.0,
            wrapLines: false,
            textView: NSView(),
            delegate: nil
        )
        return TextSelectionManager(
            layoutManager: layoutManager,
            textStorage: textStorage,
            textView: nil,
            delegate: nil
        )
    }

    func test_updateSelectionLeft() {
        let selectionManager = selectionManager()
        let locations = [2, 0, 14, 14]
        let expectedRanges = [(1, 1), (0, 0), (12, 2), (13, 1)]
        let decomposeCharacters = [false, false, false, true]

        for idx in locations.indices {
            let range = selectionManager.rangeOfSelection(
                from: locations[idx],
                direction: .backward,
                destination: .character,
                decomposeCharacters: decomposeCharacters[idx]
            )

            XCTAssert(
                range.location == expectedRanges[idx].0,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
            XCTAssert(
                range.length == expectedRanges[idx].1,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
        }
    }

    func test_updateSelectionRight() {
        let selectionManager = selectionManager()
        let locations = [2, 0, 14, 13, 12]
        let expectedRanges = [(2, 1), (0, 1), (14, 0), (12, 2), (12, 1)]
        let decomposeCharacters = [false, false, false, false, true]

        for idx in locations.indices {
            let range = selectionManager.rangeOfSelection(
                from: locations[idx],
                direction: .forward,
                destination: .character,
                decomposeCharacters: decomposeCharacters[idx]
            )

            XCTAssert(
                range.location == expectedRanges[idx].0,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
            XCTAssert(
                range.length == expectedRanges[idx].1,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
        }
    }

    func test_updateSelectionLeftWord() {
        let selectionManager = selectionManager()
        let locations = [2, 0, 12]
        let expectedRanges = [(0, 2), (0, 0), (6, 6)]

        for idx in locations.indices {
            let range = selectionManager.rangeOfSelection(
                from: locations[idx],
                direction: .backward,
                destination: .word,
                decomposeCharacters: false
            )

            XCTAssert(
                range.location == expectedRanges[idx].0,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
            XCTAssert(
                range.length == expectedRanges[idx].1,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
        }
    }

    func test_updateSelectionRightWord() {
        // "Loren Ipsum 💯"
        let selectionManager = selectionManager()
        let locations = [2, 0, 6]
        let expectedRanges = [(2, 3), (0, 5), (6, 5)]

        for idx in locations.indices {
            let range = selectionManager.rangeOfSelection(
                from: locations[idx],
                direction: .forward,
                destination: .word,
                decomposeCharacters: false
            )

            XCTAssert(
                range.location == expectedRanges[idx].0,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
            XCTAssert(
                range.length == expectedRanges[idx].1,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
        }
    }

    func test_updateSelectionLeftLine() {
        // "Loren Ipsum 💯"
        let selectionManager = selectionManager()
        let locations = [2, 0, 14, 12]
        let expectedRanges = [(0, 2), (0, 0), (0, 14), (0, 12)]

        for idx in locations.indices {
            let range = selectionManager.rangeOfSelection(
                from: locations[idx],
                direction: .backward,
                destination: .line,
                decomposeCharacters: false
            )

            XCTAssert(
                range.location == expectedRanges[idx].0,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
            XCTAssert(
                range.length == expectedRanges[idx].1,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
        }
    }

    func test_updateSelectionRightLine() {
        let selectionManager = selectionManager("Loren Ipsum 💯\nHello World")
        let locations = [2, 0, 14, 12, 17]
        let expectedRanges = [(2, 12), (0, 14), (14, 0), (12, 2), (17, 9)]

        for idx in locations.indices {
            let range = selectionManager.rangeOfSelection(
                from: locations[idx],
                direction: .forward,
                destination: .line,
                decomposeCharacters: false
            )

            XCTAssert(
                range.location == expectedRanges[idx].0,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
            XCTAssert(
                range.length == expectedRanges[idx].1,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
        }
    }

    func test_updateSelectionUpDocument() {
        let selectionManager = selectionManager("Loren Ipsum 💯\nHello World\n1\n2\n3\n")
        let locations = [0, 27, 30, 33]
        let expectedRanges = [(0, 0), (0, 27), (0, 30), (0, 33)]

        for idx in locations.indices {
            let range = selectionManager.rangeOfSelection(
                from: locations[idx],
                direction: .up,
                destination: .document,
                decomposeCharacters: false
            )

            XCTAssert(
                range.location == expectedRanges[idx].0,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
            XCTAssert(
                range.length == expectedRanges[idx].1,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
        }
    }

    func test_updateSelectionDownDocument() {
        let selectionManager = selectionManager("Loren Ipsum 💯\nHello World\n1\n2\n3\n")
        let locations = [0, 2, 27, 30, 33]
        let expectedRanges = [(0, 33), (2, 31), (27, 6), (30, 3), (33, 0)]

        for idx in locations.indices {
            let range = selectionManager.rangeOfSelection(
                from: locations[idx],
                direction: .down,
                destination: .document,
                decomposeCharacters: false
            )

            XCTAssert(
                range.location == expectedRanges[idx].0,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
            XCTAssert(
                range.length == expectedRanges[idx].1,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
        }
    }

    func test_selectionEndOfDocumentHasXPos() {
        let selectionManager = selectionManager("1\n2\n3\n")
        selectionManager.setSelectedRange(NSRange(location: 6, length: 0)) // Beyond text.length, end of doc
        XCTAssertNotNil(selectionManager.textSelections.first?.suggestedXPos)
    }
}
