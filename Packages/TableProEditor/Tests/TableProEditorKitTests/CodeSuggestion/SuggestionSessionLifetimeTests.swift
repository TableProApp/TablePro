import AppKit
@testable import TableProEditorKit
import XCTest

final class SuggestionSessionLifetimeTests: XCTestCase {
    @MainActor
    func test_showCompletions_endsSessionWhenDelegateReturnsNilItems() async throws {
        let (window, textViewController) = Mock.windowedTextViewController(theme: Mock.theme())
        defer { window.close() }
        window.orderFrontRegardless()

        let model = SuggestionViewModel()
        let delegate = LifetimeStubDelegate(items: nil)

        model.showCompletions(
            textView: textViewController,
            delegate: delegate,
            cursorPosition: CursorPosition(range: NSRange(location: 0, length: 0))
        ) { _, _ in }

        await model.itemsRequestTask?.value

        XCTAssertNil(model.activeTextView)
        XCTAssertNil(model.delegate)
        XCTAssertFalse(model.isPresented)
        XCTAssertEqual(delegate.didCloseCount, 1)
    }

    @MainActor
    func test_showCompletions_endsSessionWhenFirstResponderChangedDuringFetch() async throws {
        let (window, textViewController) = Mock.windowedTextViewController(theme: Mock.theme())
        defer { window.close() }
        window.orderFrontRegardless()
        let textView = try XCTUnwrap(textViewController.textView)
        XCTAssertTrue(window.makeFirstResponder(textView))

        let model = SuggestionViewModel()
        let delegate = LifetimeStubDelegate(items: [StubSuggestionEntry(label: "SELECT")], sleepMilliseconds: 20)

        var presentationCount = 0
        model.showCompletions(
            textView: textViewController,
            delegate: delegate,
            cursorPosition: CursorPosition(range: NSRange(location: 0, length: 0))
        ) { _, _ in presentationCount += 1 }

        window.makeFirstResponder(nil)
        await model.itemsRequestTask?.value

        XCTAssertEqual(presentationCount, 0)
        XCTAssertNil(model.activeTextView)
        XCTAssertNil(model.delegate)
        XCTAssertFalse(model.isPresented)
        XCTAssertEqual(delegate.didCloseCount, 1)
    }

    /// A session that never got a window must not absorb the keystroke that could open one.
    /// Measured before this held: one no-match prefix left the model claiming the editor, and
    /// every later prefix the stale candidates could still rank updated an invisible panel, so
    /// the popup never came back.
    @MainActor
    func test_cursorsUpdated_presentsRatherThanFilingItemsIntoAWindowThatIsNotShown() throws {
        let model = SuggestionViewModel()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let delegate = LifetimeStubDelegate(items: nil, cursorMoveItems: [StubSuggestionEntry(label: "SELECT")])

        model.activeTextView = textViewController
        model.delegate = delegate
        model.isPresented = false
        model.itemsRequestTask = nil

        var closeCount = 0
        model.cursorsUpdated(
            textView: textViewController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 1, length: 0))
        ) { closeCount += 1 }

        XCTAssertEqual(closeCount, 1)
        XCTAssertTrue(model.items.isEmpty)
    }

    @MainActor
    func test_showCompletions_supersededRequestLeavesTheLiveRequestHandleAlone() async throws {
        let (window, textViewController) = Mock.windowedTextViewController(theme: Mock.theme())
        defer { window.close() }
        window.orderFrontRegardless()

        let model = SuggestionViewModel()
        let slow = LifetimeStubDelegate(items: nil, sleepMilliseconds: 200)
        let fast = LifetimeStubDelegate(items: nil, sleepMilliseconds: 400)

        model.showCompletions(
            textView: textViewController,
            delegate: slow,
            cursorPosition: CursorPosition(range: NSRange(location: 0, length: 0))
        ) { _, _ in }
        let superseded = try XCTUnwrap(model.itemsRequestTask)

        try await Task.sleep(for: .milliseconds(20))

        model.showCompletions(
            textView: textViewController,
            delegate: fast,
            cursorPosition: CursorPosition(range: NSRange(location: 0, length: 0))
        ) { _, _ in }
        let live = try XCTUnwrap(model.itemsRequestTask)

        await superseded.value

        XCTAssertNotNil(model.itemsRequestTask)
        XCTAssertFalse(live.isCancelled)

        model.willClose()
    }

    /// `completionWindowDidSelect` is public and fires synchronously from inside the presentation,
    /// so a conformer may dismiss from it. The panel must not go up anyway over a session that no
    /// longer exists.
    @MainActor
    func test_showCompletions_doesNotPresentWhenTheSelectionCallbackDismissedTheSession() async throws {
        let (window, textViewController) = Mock.keyWindowedTextViewController()
        defer { window.close() }
        XCTAssertIdentical(window.firstResponder, textViewController.textView)

        let model = SuggestionViewModel()
        let delegate = LifetimeStubDelegate(items: [StubSuggestionEntry(label: "SELECT")])
        delegate.onSelect = { model.willClose() }

        var presentationCount = 0
        model.showCompletions(
            textView: textViewController,
            delegate: delegate,
            cursorPosition: CursorPosition(range: NSRange(location: 0, length: 0))
        ) { _, _ in presentationCount += 1 }

        await model.itemsRequestTask?.value

        XCTAssertEqual(presentationCount, 0)
        XCTAssertFalse(model.isPresented)
        XCTAssertNil(model.activeTextView)
    }

    /// A shown panel posts `willCloseNotification` from inside `super.close()`, so the explicit
    /// call behind it must not run a second teardown over whatever that one's delegate callback
    /// started.
    @MainActor
    func test_controllerClose_cleansUpOncePerCloseForAShownPanel() throws {
        let controller = SuggestionController()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let delegate = LifetimeStubDelegate(items: nil)

        controller.model.activeTextView = textViewController
        controller.model.delegate = delegate
        controller.model.isPresented = true
        controller.window?.orderFrontRegardless()

        controller.close()

        XCTAssertEqual(delegate.didCloseCount, 1)
        XCTAssertNil(controller.model.activeTextView)
        XCTAssertFalse(controller.model.isPresented)
    }

    @MainActor
    func test_controllerClose_endsTheSessionEvenWhenTheWindowWasNeverShown() throws {
        let controller = SuggestionController()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let delegate = LifetimeStubDelegate(items: nil)

        controller.model.activeTextView = textViewController
        controller.model.delegate = delegate
        controller.model.isPresented = true

        controller.close()

        XCTAssertNil(controller.model.activeTextView)
        XCTAssertNil(controller.model.delegate)
        XCTAssertFalse(controller.model.isPresented)
        XCTAssertEqual(delegate.didCloseCount, 1)

        controller.model.activeTextView = textViewController
        controller.model.delegate = delegate

        controller.close()

        XCTAssertNil(controller.model.activeTextView)
        XCTAssertEqual(delegate.didCloseCount, 2)
    }
}

@MainActor
private final class LifetimeStubDelegate: CodeSuggestionDelegate {
    private let items: [CodeSuggestionEntry]?
    private let cursorMoveItems: [CodeSuggestionEntry]?
    private let sleepMilliseconds: Int
    private(set) var didCloseCount = 0
    var onSelect: (() -> Void)?

    init(
        items: [CodeSuggestionEntry]?,
        cursorMoveItems: [CodeSuggestionEntry]? = nil,
        sleepMilliseconds: Int = 0
    ) {
        self.items = items
        self.cursorMoveItems = cursorMoveItems
        self.sleepMilliseconds = sleepMilliseconds
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition,
        isManualTrigger: Bool
    ) async -> CodeSuggestionResponse? {
        if sleepMilliseconds > 0 {
            do {
                try await Task.sleep(for: .milliseconds(sleepMilliseconds))
            } catch {
                return nil
            }
        }
        guard let items else { return nil }
        return .answeringAnEmptyPrefix(items, at: cursorPosition)
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        cursorMoveItems
    }

    func completionWindowDidClose() {
        didCloseCount += 1
    }

    func completionWindowDidSelect(item: CodeSuggestionEntry) {
        onSelect?()
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {}
}
