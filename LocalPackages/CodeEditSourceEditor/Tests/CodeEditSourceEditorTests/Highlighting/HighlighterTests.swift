import XCTest
import CodeEditTextView
import CodeEditLanguages
@testable import CodeEditSourceEditor

final class HighlighterTests: XCTestCase {
    class MockHighlightProvider: HighlightProviding {
        var setUpCount = 0
        var queryCount = 0
        var queryResponse: @MainActor () -> (Result<[HighlightRange], Error>)

        init(setUpCount: Int = 0, queryResponse: @escaping () -> Result<[HighlightRange], Error> = { .success([]) }) {
            self.setUpCount = setUpCount
            self.queryResponse = queryResponse
        }

        func setUp(textView: TextView, codeLanguage: CodeLanguage) {
            setUpCount += 1
        }

        func applyEdit(
            textView: TextView,
            range: NSRange,
            delta: Int,
            completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
        ) {
            completion(.success(.init(integersIn: NSRange(location: 0, length: 10))))
        }

        func queryHighlightsFor(
            textView: TextView,
            range: NSRange,
            completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void
        ) {
            queryCount += 1
            completion(queryResponse())
        }
    }

    class MockAttributeProvider: ThemeAttributesProviding {
        func attributesFor(_ capture: CaptureName?) -> [NSAttributedString.Key: Any] { [:] }
    }

    class SentryStorageDelegate: NSObject, NSTextStorageDelegate {
        var editedIndices: IndexSet = IndexSet()

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int) {
                editedIndices.insert(integersIn: editedRange)
            }
    }

    var attributeProvider: MockAttributeProvider!
    var textView: TextView!

    override func setUp() {
        attributeProvider = MockAttributeProvider()
        textView = Mock.textView()
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
    }

    @MainActor
    func test_canceledHighlightsAreInvalidated() {
        var didQueryOnce = false
        var didQueryAgain = false

        let highlightProvider = MockHighlightProvider {
            didQueryOnce = true
            if didQueryOnce {
                didQueryAgain = true
                return .success([]) // succeed second
            }
            return .failure(HighlightProvidingError.operationCancelled) // fail first, causing an invalidation
        }
        let attributeProvider = MockAttributeProvider()
        let textView = Mock.textView()
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        textView.setText("Hello World!")
        let highlighter = Mock.highlighter(
            textView: textView,
            highlightProviders: [highlightProvider],
            attributeProvider: attributeProvider
        )

        highlighter.invalidate()

        XCTAssertTrue(didQueryOnce, "Highlighter did not invalidate text.")
        XCTAssertTrue(
            didQueryAgain,
            "Highlighter did not query again after cancelling the first request"
        )
    }

    @MainActor
    func test_highlightsDoNotInvalidateEntireTextView() {
        let highlightProvider = TreeSitterClient()
        highlightProvider.forceSyncOperation = true
        textView.setText("func helloWorld() {\n\tprint(\"Hello World!\")\n}")

        let highlighter = Mock.highlighter(
            textView: textView,
            highlightProviders: [highlightProvider],
            attributeProvider: attributeProvider
        )

        highlighter.invalidate()

        let sentryStorage = SentryStorageDelegate()
        textView.addStorageDelegate(sentryStorage)

        let invalidSet = IndexSet(integersIn: NSRange(location: 0, length: 24))
        highlighter.invalidate(invalidSet) // Invalidate first line

        XCTAssertEqual(sentryStorage.editedIndices, invalidSet) // Should only cause highlights on the first line
    }

    @MainActor
    func test_insertedNewHighlightProvider() {
        let highlightProvider1 = MockHighlightProvider(queryResponse: { .success([]) })
        let attributeProvider = MockAttributeProvider()
        let textView = Mock.textView()
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        textView.setText("Hello World!")
        let highlighter = Mock.highlighter(
            textView: textView,
            highlightProviders: [highlightProvider1],
            attributeProvider: attributeProvider
        )

        XCTAssertEqual(highlightProvider1.setUpCount, 1, "Highlighter 1 did not set up")

        let newProvider = MockHighlightProvider(queryResponse: { .success([]) })
        highlighter.setProviders([highlightProvider1, newProvider])

        XCTAssertEqual(highlightProvider1.setUpCount, 1, "Highlighter 1 set up again")
        XCTAssertEqual(newProvider.setUpCount, 1, "New highlighter did not set up")
    }

    @MainActor
    func test_removedHighlightProvider() {
        let highlightProvider1 = MockHighlightProvider()
        let highlightProvider2 = MockHighlightProvider()

        let attributeProvider = MockAttributeProvider()
        let textView = Mock.textView()
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        textView.setText("Hello World!")

        let highlighter = Mock.highlighter(
            textView: textView,
            highlightProviders: [highlightProvider1, highlightProvider2],
            attributeProvider: attributeProvider
        )

        XCTAssertEqual(highlightProvider1.setUpCount, 1, "Highlighter 1 did not set up")
        XCTAssertEqual(highlightProvider2.setUpCount, 1, "Highlighter 2 did not set up")

        highlighter.setProviders([highlightProvider1])

        highlighter.invalidate()

        XCTAssertEqual(highlightProvider1.queryCount, 1, "Highlighter 1 was not queried")
        XCTAssertEqual(highlightProvider2.queryCount, 0, "Removed highlighter was queried")
    }

    @MainActor
    func test_movedHighlightProviderIsNotSetUpAgain() {
        let highlightProvider1 = MockHighlightProvider()
        let highlightProvider2 = MockHighlightProvider()

        let attributeProvider = MockAttributeProvider()
        let textView = Mock.textView()
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        textView.setText("Hello World!")

        let highlighter = Mock.highlighter(
            textView: textView,
            highlightProviders: [highlightProvider1, highlightProvider2],
            attributeProvider: attributeProvider
        )

        XCTAssertEqual(highlightProvider1.setUpCount, 1, "Highlighter 1 did not set up")
        XCTAssertEqual(highlightProvider2.setUpCount, 1, "Highlighter 2 did not set up")

        highlighter.setProviders([highlightProvider2, highlightProvider1])

        highlighter.invalidate()

        XCTAssertEqual(highlightProvider1.queryCount, 1, "Highlighter 1 was not queried")
        XCTAssertEqual(highlightProvider2.queryCount, 1, "Highlighter 2 was not queried")
    }

    @MainActor
    func test_randomHighlightProvidersChanging() {
        for _ in 0..<25 {
            let highlightProviders = (0..<Int.random(in: 10..<20)).map { _ in MockHighlightProvider() }

            let firstSet = highlightProviders.shuffled().filter({ _ in Bool.random() })
            let secondSet = highlightProviders.shuffled().filter({ _ in Bool.random() })
            let thirdSet = highlightProviders.shuffled().filter({ _ in Bool.random() })

            let attributeProvider = MockAttributeProvider()
            let textView = Mock.textView()
            textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
            textView.setText("Hello World!")

            let highlighter = Mock.highlighter(
                textView: textView,
                highlightProviders: firstSet,
                attributeProvider: attributeProvider
            )

            highlighter.invalidate()

            XCTAssertTrue(firstSet.allSatisfy({ $0.setUpCount == 1 }), "Not all in first batch were set up")
            XCTAssertTrue(firstSet.allSatisfy({ $0.queryCount == 1 }), "Not all in first batch were queried")

            highlighter.setProviders(secondSet)
            highlighter.invalidate()

            XCTAssertTrue(secondSet.allSatisfy({ $0.setUpCount == 1 }), "All in second batch were not set up twice")
            XCTAssertTrue(secondSet.allSatisfy({ $0.queryCount >= 1 }), "Not all in second batch were queried")

            highlighter.setProviders(thirdSet)
            highlighter.invalidate()

            // Can't check for == 1 here because some might be removed in #2 and added back in in #3
            XCTAssertTrue(thirdSet.allSatisfy({ $0.setUpCount >= 1 }), "Not all in third batch were set up")
            XCTAssertTrue(thirdSet.allSatisfy({ $0.queryCount >= 1 }), "Not all in third batch were queried")
        }
    }

    // This test isn't testing much highlighter functionality. However, we've seen crashes and other errors after normal
    // editing that were caused by the highlighter and would only have been caught by an integration test like this.
    @MainActor
    func test_editFile() {
        let highlightProvider = TreeSitterClient()
        highlightProvider.forceSyncOperation = true
        textView.setText("func helloWorld() {\n\tprint(\"Hello World!\")\n}") // 44 chars

        let highlighter = Mock.highlighter(
            textView: textView,
            highlightProviders: [highlightProvider],
            attributeProvider: attributeProvider
        )
        textView.addStorageDelegate(highlighter)
        highlighter.setLanguage(language: .swift)
        highlighter.invalidate()

        // Delete Characters
        textView.replaceCharacters(in: [NSRange(location: 43, length: 1)], with: "")
        textView.replaceCharacters(in: [NSRange(location: 0, length: 4)], with: "")
        textView.replaceCharacters(in: [NSRange(location: 6, length: 5)], with: "")
        textView.replaceCharacters(in: [NSRange(location: 25, length: 5)], with: "")

        XCTAssertEqual(textView.string, " hello() {\n\tprint(\"Hello !\")\n")

        // Insert Characters
        textView.replaceCharacters(in: [NSRange(location: 29, length: 0)], with: "}")
        textView.replaceCharacters(
            in: [NSRange(location: 25, length: 0), NSRange(location: 6, length: 0)],
            with: "World"
        )
        // emulate typing with a cursor
        textView.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("f")
        textView.insertText("u")
        textView.insertText("n")
        textView.insertText("c")
        XCTAssertEqual(textView.string, "func helloWorld() {\n\tprint(\"Hello World!\")\n}")

        // Replace contents
        textView.replaceCharacters(in: textView.documentRange, with: "")
        textView.insertText("func helloWorld() {\n\tprint(\"Hello World!\")\n}")
        XCTAssertEqual(textView.string, "func helloWorld() {\n\tprint(\"Hello World!\")\n}")
    }
}
