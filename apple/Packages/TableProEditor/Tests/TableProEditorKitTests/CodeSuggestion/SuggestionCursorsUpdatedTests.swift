import AppKit
@testable import TableProEditorKit
import TableProTestSupport
import Testing

@MainActor
struct SuggestionCursorsUpdatedTests {
    @MainActor
    @Test func test_cursorsUpdated_keepsWindowOpenWhileRequestIsInFlight() throws {
        let model = SuggestionViewModel()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let delegate = FilteringStubDelegate(itemsOnCursorMove: nil)

        model.activeTextView = textViewController
        model.delegate = delegate
        model.isPresented = true
        model.items = [StubSuggestionEntry(label: "SELECT")]
        model.itemsRequestTask = Task { try? await Task.sleep(for: .seconds(10)) }
        defer { model.itemsRequestTask?.cancel() }

        var closeCount = 0
        model.cursorsUpdated(
            textView: textViewController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 1, length: 0))
        ) { closeCount += 1 }

        #expect(closeCount == 0)
        #expect(model.itemsRequestTask != nil)
    }

    @MainActor
    @Test func test_cursorsUpdated_filtersItemsInPlaceWhenDelegateProvidesThem() throws {
        let model = SuggestionViewModel()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let filtered: [CodeSuggestionEntry] = [StubSuggestionEntry(label: "SELECT"), StubSuggestionEntry(label: "SET")]
        let delegate = FilteringStubDelegate(itemsOnCursorMove: filtered)

        model.activeTextView = textViewController
        model.delegate = delegate
        model.isPresented = true
        model.items = [StubSuggestionEntry(label: "stale")]
        model.selectedIndex = 0

        var closeCount = 0
        model.cursorsUpdated(
            textView: textViewController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 2, length: 0))
        ) { closeCount += 1 }

        #expect(closeCount == 0)
        #expect(model.items.map(\.label) == ["SELECT", "SET"])
        #expect(model.selectedIndex == 0)
    }

    @MainActor
    @Test func test_cursorsUpdated_closesWhenNoItemsAndNoRequestInFlight() throws {
        let model = SuggestionViewModel()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let delegate = FilteringStubDelegate(itemsOnCursorMove: nil)

        model.activeTextView = textViewController
        model.delegate = delegate
        model.items = [StubSuggestionEntry(label: "SELECT")]
        model.itemsRequestTask = nil

        var closeCount = 0
        model.cursorsUpdated(
            textView: textViewController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 0, length: 0))
        ) { closeCount += 1 }

        #expect(closeCount == 1)
    }

    @MainActor
    @Test func test_cursorsUpdated_cancelsRequestAndClosesForDifferentTextView() throws {
        let model = SuggestionViewModel()
        let activeController = Mock.textViewController(theme: Mock.theme())
        let otherController = Mock.textViewController(theme: Mock.theme())
        let delegate = FilteringStubDelegate(itemsOnCursorMove: [StubSuggestionEntry(label: "SELECT")])

        model.activeTextView = activeController
        model.delegate = delegate
        model.itemsRequestTask = Task { try? await Task.sleep(for: .seconds(10)) }

        var closeCount = 0
        model.cursorsUpdated(
            textView: otherController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 0, length: 0))
        ) { closeCount += 1 }

        #expect(closeCount == 1)
        #expect(model.itemsRequestTask == nil)
    }

    // MARK: - A partial pool

    @MainActor
    @Test func test_cursorsUpdated_typingIntoAPartialPoolKeepsTheWindowAndShowsTheFreshItems() async throws {
        let model = SuggestionViewModel()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let fetch = AsyncGate()
        let delegate = PartialPoolStubDelegate(pool: ["t045"], isPartial: true, fresh: ["t450", "t451"], fetch: fetch)
        var closeCount = 0
        present(model, in: textViewController, delegate: delegate) { closeCount += 1 }

        model.cursorsUpdated(
            textView: textViewController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 3, length: 0)),
            presentIfNot: true
        ) { closeCount += 1 }
        let pooled = model.items.map(\.label)
        await fetch.open()
        await model.itemsRequestTask?.value

        #expect(pooled == ["t045"])
        #expect(closeCount == 0)
        #expect(model.isPresented)
        #expect(model.items.map(\.label) == ["t450", "t451"])
        #expect(delegate.shownItemCounts == [2])
    }

    @MainActor
    @Test(arguments: [true, false])
    func test_cursorsUpdated_aPoolThatCanAnswerAsksNothing(typed: Bool) async throws {
        let model = SuggestionViewModel()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let delegate = PartialPoolStubDelegate(pool: ["select"], isPartial: false, fresh: ["set"], fetch: AsyncGate())
        var closeCount = 0
        present(model, in: textViewController, delegate: delegate) { closeCount += 1 }

        model.cursorsUpdated(
            textView: textViewController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 2, length: 0)),
            presentIfNot: typed
        ) { closeCount += 1 }

        #expect(closeCount == 0)
        #expect(model.items.map(\.label) == ["select"])
        #expect(model.itemsRequestTask == nil)
        #expect(delegate.requestCount == 0)
    }

    // A deletion is not typing: the trigger model leaves it to the selection change, which reports a plain move.
    @MainActor
    @Test func test_cursorsUpdated_aDeletionThePoolCannotAnswerShowsTheFreshItemsInPlace() async throws {
        let model = SuggestionViewModel()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let fetch = AsyncGate()
        let delegate = PartialPoolStubDelegate(pool: ["ab1"], isPartial: true, fresh: ["ab1", "ac1"], fetch: fetch)
        var closeCount = 0
        present(model, in: textViewController, delegate: delegate) { closeCount += 1 }

        model.cursorsUpdated(
            textView: textViewController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 1, length: 0))
        ) { closeCount += 1 }
        await fetch.open()
        await model.itemsRequestTask?.value

        #expect(closeCount == 0)
        #expect(model.items.map(\.label) == ["ab1", "ac1"])
    }

    @MainActor
    @Test func test_cursorsUpdated_freshItemsKeepTheRowTheUserChose() async throws {
        let model = SuggestionViewModel()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let fetch = AsyncGate()
        let delegate = PartialPoolStubDelegate(pool: ["a1", "b2"], isPartial: true, fresh: ["c3", "b2"], fetch: fetch)
        present(model, in: textViewController, delegate: delegate) {}

        model.cursorsUpdated(
            textView: textViewController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 2, length: 0)),
            presentIfNot: true
        ) {}
        model.moveDown()
        await fetch.open()
        await model.itemsRequestTask?.value

        #expect(model.items.map(\.label) == ["c3", "b2"])
        #expect(model.selectedItem?.label == "b2")
    }

    @MainActor
    @Test func test_cursorsUpdated_freshItemsStartAtTheFirstRowWhenTheChosenRowIsGone() async throws {
        let model = SuggestionViewModel()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let fetch = AsyncGate()
        let delegate = PartialPoolStubDelegate(pool: ["a1", "b2"], isPartial: true, fresh: ["c3", "d4"], fetch: fetch)
        present(model, in: textViewController, delegate: delegate) {}

        model.cursorsUpdated(
            textView: textViewController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 2, length: 0)),
            presentIfNot: true
        ) {}
        model.moveDown()
        await fetch.open()
        await model.itemsRequestTask?.value

        #expect(model.selectedIndex == 0)
    }

    @MainActor
    @Test func test_cursorsUpdated_anEditAfterAChoiceStartsTheFreshItemsAtTheFirstRow() async throws {
        let model = SuggestionViewModel()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let fetch = AsyncGate()
        let delegate = PartialPoolStubDelegate(pool: ["a1", "b2"], isPartial: true, fresh: ["c3", "b2"], fetch: fetch)
        present(model, in: textViewController, delegate: delegate) {}

        model.cursorsUpdated(
            textView: textViewController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 2, length: 0)),
            presentIfNot: true
        ) {}
        model.moveDown()
        model.cursorsUpdated(
            textView: textViewController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 3, length: 0)),
            presentIfNot: true
        ) {}
        await fetch.open()
        await model.itemsRequestTask?.value

        #expect(model.items.map(\.label) == ["c3", "b2"])
        #expect(model.selectedIndex == 0)
    }

    @MainActor
    @Test func test_cursorsUpdated_aFreshRequestThatAnswersNothingClosesTheWindow() async throws {
        let model = SuggestionViewModel()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let fetch = AsyncGate()
        let delegate = PartialPoolStubDelegate(pool: ["t045"], isPartial: true, fresh: nil, fetch: fetch)
        var moveCloses = 0
        var requestedCloses = 0
        present(model, in: textViewController, delegate: delegate) { requestedCloses += 1 }

        model.cursorsUpdated(
            textView: textViewController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 3, length: 0)),
            presentIfNot: true
        ) { moveCloses += 1 }
        await fetch.open()
        await model.itemsRequestTask?.value

        #expect(moveCloses == 0)
        #expect(requestedCloses == 1)
        #expect(delegate.shownItemCounts.isEmpty)
    }

    @MainActor
    @Test func test_cursorsUpdated_aMoveThePoolCannotAnswerClosesWhileARefreshRuns() async throws {
        let model = SuggestionViewModel()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let delegate = PartialPoolStubDelegate(pool: ["t045"], isPartial: true, fresh: ["t450"], fetch: AsyncGate())
        present(model, in: textViewController, delegate: delegate) {}
        model.cursorsUpdated(
            textView: textViewController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 3, length: 0)),
            presentIfNot: true
        ) {}
        defer { model.itemsRequestTask?.cancel() }

        delegate.pool = nil
        var closeCount = 0
        model.cursorsUpdated(
            textView: textViewController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 4, length: 0)),
            presentIfNot: true
        ) { closeCount += 1 }

        #expect(closeCount == 1)
    }

    @MainActor
    private func present(
        _ model: SuggestionViewModel,
        in textViewController: TextViewController,
        delegate: CodeSuggestionDelegate,
        onRequestClose: @escaping () -> Void
    ) {
        model.activeTextView = textViewController
        model.delegate = delegate
        model.isPresented = true
        model.items = [StubSuggestionEntry(label: "t000")]
        model.onRequestClose = onRequestClose
    }
}

private final class FilteringStubDelegate: CodeSuggestionDelegate {
    private let itemsOnCursorMove: [CodeSuggestionEntry]?

    init(itemsOnCursorMove: [CodeSuggestionEntry]?) {
        self.itemsOnCursorMove = itemsOnCursorMove
    }

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
        itemsOnCursorMove
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {}
}

@MainActor
private final class PartialPoolStubDelegate: CodeSuggestionDelegate {
    var pool: [String]?
    private let isPartial: Bool
    private let fresh: [String]?
    private let fetch: AsyncGate
    private(set) var requestCount = 0
    private(set) var shownItemCounts: [Int] = []

    init(pool: [String]?, isPartial: Bool, fresh: [String]?, fetch: AsyncGate) {
        self.pool = pool
        self.isPartial = isPartial
        self.fresh = fresh
        self.fetch = fetch
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition,
        isManualTrigger: Bool
    ) async -> CodeSuggestionResponse? {
        requestCount += 1
        await fetch.wait()
        guard let fresh else { return nil }
        return .answeringAnEmptyPrefix(
            fresh.map { StubSuggestionEntry(label: $0) },
            at: textView.cursorPositions.first ?? cursorPosition
        )
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        pool?.map { StubSuggestionEntry(label: $0) }
    }

    func completionNeedsFreshItems(textView: TextViewController, cursorPosition: CursorPosition) -> Bool {
        isPartial
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
