import AppKit
@testable import TableProEditorKit
import TableProTestSupport
import XCTest

final class SuggestionShowCompletionsGuardTests: XCTestCase {
    @MainActor
    func test_showCompletions_dropsPresentationWhenFirstResponderChangedDuringFetch() async throws {
        let (window, textViewController) = Mock.windowedTextViewController(theme: Mock.theme())
        defer { window.close() }
        window.orderFrontRegardless()
        let textView = try XCTUnwrap(textViewController.textView)
        XCTAssertTrue(window.makeFirstResponder(textView))

        let model = SuggestionViewModel()
        let fetch = AsyncGate()
        let delegate = DelayedStubDelegate(items: [StubSuggestionEntry(label: "SELECT")], fetch: fetch)

        var presentationCount = 0
        model.showCompletions(
            textView: textViewController,
            delegate: delegate,
            cursorPosition: CursorPosition(range: NSRange(location: 0, length: 0))
        ) { _, _ in
            presentationCount += 1
        }

        await fetch.arrived(1)
        window.makeFirstResponder(nil)
        await fetch.open()
        await model.itemsRequestTask?.value

        XCTAssertEqual(presentationCount, 0)
        XCTAssertEqual(delegate.shownItemCounts, [])
    }

    @MainActor
    func test_showCompletions_presentsWhenEditorStillFocused() async throws {
        let (window, textViewController) = Mock.windowedTextViewController(theme: Mock.theme())
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        guard (try? await waitUntil(timeout: .milliseconds(100)) { window.isKeyWindow }) != nil else {
            throw XCTSkip("Window cannot become key in this environment")
        }

        let textView = try XCTUnwrap(textViewController.textView)
        XCTAssertTrue(window.makeFirstResponder(textView))

        let model = SuggestionViewModel()
        let fetch = AsyncGate()
        await fetch.open()
        let delegate = DelayedStubDelegate(items: [StubSuggestionEntry(label: "SELECT")], fetch: fetch)

        var presentedWindows: [NSWindow] = []
        model.showCompletions(
            textView: textViewController,
            delegate: delegate,
            cursorPosition: CursorPosition(range: NSRange(location: 0, length: 0))
        ) { parentWindow, _ in
            presentedWindows.append(parentWindow)
        }

        await model.itemsRequestTask?.value

        XCTAssertEqual(presentedWindows.count, 1)
        XCTAssertIdentical(presentedWindows.first, window)
        XCTAssertEqual(delegate.shownItemCounts, [1])
    }
}

@MainActor
private final class DelayedStubDelegate: CodeSuggestionDelegate {
    let items: [CodeSuggestionEntry]
    private let fetch: AsyncGate
    private(set) var shownItemCounts: [Int] = []

    init(items: [CodeSuggestionEntry], fetch: AsyncGate) {
        self.items = items
        self.fetch = fetch
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition,
        isManualTrigger: Bool
    ) async -> CodeSuggestionResponse? {
        await fetch.wait()
        return .answeringAnEmptyPrefix(items, at: cursorPosition)
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        nil
    }

    func completionWindowDidShow(textView: TextViewController, itemCount: Int) {
        shownItemCounts.append(itemCount)
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {}
}
