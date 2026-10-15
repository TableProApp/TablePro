import AppKit
@testable import TableProEditorKit
import TableProTestSupport
import Testing

@MainActor
struct SuggestionSessionLifetimeTests {
    @MainActor
    @Test func test_showCompletions_endsSessionWhenDelegateReturnsNilItems() async throws {
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

        #expect(model.activeTextView == nil)
        #expect(model.delegate == nil)
        #expect(!model.isPresented)
        #expect(delegate.didCloseCount == 1)
    }

    @MainActor
    @Test func test_showCompletions_endsSessionWhenFirstResponderChangedDuringFetch() async throws {
        let (window, textViewController) = Mock.windowedTextViewController(theme: Mock.theme())
        defer { window.close() }
        window.orderFrontRegardless()
        let textView = try #require(textViewController.textView)
        #expect(window.makeFirstResponder(textView))

        let model = SuggestionViewModel()
        let fetch = AsyncGate()
        let delegate = LifetimeStubDelegate(items: [StubSuggestionEntry(label: "SELECT")], fetch: fetch)

        var presentationCount = 0
        model.showCompletions(
            textView: textViewController,
            delegate: delegate,
            cursorPosition: CursorPosition(range: NSRange(location: 0, length: 0))
        ) { _, _ in presentationCount += 1 }

        await fetch.arrived(1)
        window.makeFirstResponder(nil)
        await fetch.open()
        await model.itemsRequestTask?.value

        #expect(presentationCount == 0)
        #expect(model.activeTextView == nil)
        #expect(model.delegate == nil)
        #expect(!model.isPresented)
        #expect(delegate.didCloseCount == 1)
    }

    /// A session that never got a window must not absorb the keystroke that could open one.
    /// Measured before this held: one no-match prefix left the model claiming the editor, and
    /// every later prefix the stale candidates could still rank updated an invisible panel, so
    /// the popup never came back.
    @MainActor
    @Test func test_cursorsUpdated_presentsRatherThanFilingItemsIntoAWindowThatIsNotShown() throws {
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

        #expect(closeCount == 1)
        #expect(model.items.isEmpty)
    }

    @MainActor
    @Test func test_showCompletions_supersededRequestLeavesTheLiveRequestHandleAlone() async throws {
        let (window, textViewController) = Mock.windowedTextViewController(theme: Mock.theme())
        defer { window.close() }
        window.orderFrontRegardless()

        let model = SuggestionViewModel()
        let slowFetch = AsyncGate()
        let liveFetch = AsyncGate()
        let slow = LifetimeStubDelegate(items: nil, fetch: slowFetch)
        let fast = LifetimeStubDelegate(items: nil, fetch: liveFetch)

        model.showCompletions(
            textView: textViewController,
            delegate: slow,
            cursorPosition: CursorPosition(range: NSRange(location: 0, length: 0))
        ) { _, _ in }
        let superseded = try #require(model.itemsRequestTask)

        await slowFetch.arrived(1)

        model.showCompletions(
            textView: textViewController,
            delegate: fast,
            cursorPosition: CursorPosition(range: NSRange(location: 0, length: 0))
        ) { _, _ in }
        let live = try #require(model.itemsRequestTask)

        await slowFetch.open()
        await superseded.value

        #expect(model.itemsRequestTask != nil)
        #expect(!live.isCancelled)

        model.willClose()
        await liveFetch.open()
    }

    /// `completionWindowDidSelect` is public and fires synchronously from inside the presentation,
    /// so a conformer may dismiss from it. The panel must not go up anyway over a session that no
    /// longer exists.
    @MainActor
    @Test func test_showCompletions_doesNotPresentWhenTheSelectionCallbackDismissedTheSession() async throws {
        let (window, textViewController) = Mock.keyWindowedTextViewController()
        defer { window.close() }
        #expect(window.firstResponder === textViewController.textView)

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

        #expect(presentationCount == 0)
        #expect(!model.isPresented)
        #expect(model.activeTextView == nil)
    }

    /// A shown panel posts `willCloseNotification` from inside `super.close()`, so the explicit
    /// call behind it must not run a second teardown over whatever that one's delegate callback
    /// started.
    @MainActor
    @Test func test_controllerClose_cleansUpOncePerCloseForAShownPanel() throws {
        let controller = SuggestionController()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let delegate = LifetimeStubDelegate(items: nil)

        controller.model.activeTextView = textViewController
        controller.model.delegate = delegate
        controller.model.isPresented = true
        controller.window?.orderFrontRegardless()

        controller.close()

        #expect(delegate.didCloseCount == 1)
        #expect(controller.model.activeTextView == nil)
        #expect(!controller.model.isPresented)
    }

    @MainActor
    @Test func test_controllerClose_endsTheSessionEvenWhenTheWindowWasNeverShown() throws {
        let controller = SuggestionController()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let delegate = LifetimeStubDelegate(items: nil)

        controller.model.activeTextView = textViewController
        controller.model.delegate = delegate
        controller.model.isPresented = true

        controller.close()

        #expect(controller.model.activeTextView == nil)
        #expect(controller.model.delegate == nil)
        #expect(!controller.model.isPresented)
        #expect(delegate.didCloseCount == 1)

        controller.model.activeTextView = textViewController
        controller.model.delegate = delegate

        controller.close()

        #expect(controller.model.activeTextView == nil)
        #expect(delegate.didCloseCount == 2)
    }
}

@MainActor
private final class LifetimeStubDelegate: CodeSuggestionDelegate {
    private let items: [CodeSuggestionEntry]?
    private let cursorMoveItems: [CodeSuggestionEntry]?
    private let fetch: AsyncGate?
    private(set) var didCloseCount = 0
    var onSelect: (() -> Void)?

    init(
        items: [CodeSuggestionEntry]?,
        cursorMoveItems: [CodeSuggestionEntry]? = nil,
        fetch: AsyncGate? = nil
    ) {
        self.items = items
        self.cursorMoveItems = cursorMoveItems
        self.fetch = fetch
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition,
        isManualTrigger: Bool
    ) async -> CodeSuggestionResponse? {
        await fetch?.wait()
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
