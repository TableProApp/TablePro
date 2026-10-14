import AppKit
@testable import TableProEditorKit
import Testing

@MainActor
struct SuggestionApplyTests {
    @MainActor
    @Test func test_apply_invokesOnApplyCallback() throws {
        let model = SuggestionViewModel()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let delegate = StubSuggestionDelegate()
        let item = StubSuggestionEntry(label: "users")

        model.activeTextView = textViewController
        model.delegate = delegate
        model.items = [item]
        model.selectedIndex = 0

        var onApplyCount = 0
        model.onApply = { onApplyCount += 1 }

        model.applySelectedItem(item: item)

        #expect(onApplyCount == 1)
        #expect(delegate.applyCallCount == 1)
    }

    @MainActor
    @Test func test_apply_ignoresTriggersFiredByTheInsertionItself() throws {
        let model = SuggestionViewModel()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let delegate = StubSuggestionDelegate()
        let item = StubSuggestionEntry(label: "users")

        model.activeTextView = textViewController
        model.delegate = delegate
        model.items = [item]
        model.selectedIndex = 0

        var closeCount = 0
        delegate.applyHook = { [weak model] in
            guard let model else { return }
            #expect(model.isApplyingCompletion)
            model.cursorsUpdated(
                textView: textViewController,
                delegate: delegate,
                position: CursorPosition(range: NSRange(location: 5, length: 0))
            ) { closeCount += 1 }
            model.showCompletions(
                textView: textViewController,
                delegate: delegate,
                cursorPosition: CursorPosition(range: NSRange(location: 5, length: 0))
            ) { _, _ in }
        }

        model.applySelectedItem(item: item)

        #expect(closeCount == 0)
        #expect(model.itemsRequestTask == nil)
        #expect(!model.isApplyingCompletion)
        #expect(model.items.map(\.label) == ["users"])
    }

    @MainActor
    @Test func test_willClose_notifiesDelegateOnce() throws {
        let model = SuggestionViewModel()
        let delegate = StubSuggestionDelegate()
        model.delegate = delegate

        model.willClose()

        #expect(delegate.didCloseCount == 1)
        #expect(model.delegate == nil)
    }

    @MainActor
    @Test func test_apply_skipsCallbackWhenActiveTextViewIsNil() throws {
        let model = SuggestionViewModel()
        let delegate = StubSuggestionDelegate()
        let item = StubSuggestionEntry(label: "users")

        model.delegate = delegate
        model.items = [item]

        var onApplyCount = 0
        model.onApply = { onApplyCount += 1 }

        model.applySelectedItem(item: item)

        #expect(onApplyCount == 0)
        #expect(delegate.applyCallCount == 0)
    }

    @MainActor
    @Test func test_nsWindowClose_clearsModelState() throws {
        let controller = SuggestionController()
        let textViewController = Mock.textViewController(theme: Mock.theme())

        controller.model.activeTextView = textViewController
        controller.model.delegate = StubSuggestionDelegate()
        controller.model.items = [StubSuggestionEntry(label: "users")]
        controller.model.selectedIndex = 0

        controller.window?.close()

        #expect(controller.model.activeTextView == nil)
        #expect(controller.model.items.isEmpty)
    }

    @MainActor
    @Test func test_controllerClose_clearsModelState() throws {
        let controller = SuggestionController()
        let textViewController = Mock.textViewController(theme: Mock.theme())

        controller.model.activeTextView = textViewController
        controller.model.delegate = StubSuggestionDelegate()
        controller.model.items = [StubSuggestionEntry(label: "users")]
        controller.model.selectedIndex = 0

        controller.close()

        #expect(controller.model.activeTextView == nil)
        #expect(controller.model.items.isEmpty)
    }

    @MainActor
    @Test func test_onBackgroundTap_closesControllerAndClearsModelState() throws {
        let controller = SuggestionController()
        let textViewController = Mock.textViewController(theme: Mock.theme())

        controller.model.activeTextView = textViewController
        controller.model.delegate = StubSuggestionDelegate()
        controller.model.items = [StubSuggestionEntry(label: "users")]
        controller.model.selectedIndex = 0

        controller.model.onBackgroundTap?()

        #expect(controller.model.activeTextView == nil)
        #expect(controller.model.items.isEmpty)
    }
}

private final class StubSuggestionDelegate: CodeSuggestionDelegate {
    var applyCallCount = 0
    var didCloseCount = 0
    var applyHook: (@MainActor () -> Void)?

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition,
        isManualTrigger: Bool
    ) async -> CodeSuggestionResponse? {
        nil
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        nil
    }

    @MainActor
    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        applyCallCount += 1
        applyHook?()
    }

    func completionWindowDidClose() {
        didCloseCount += 1
    }
}
