import AppKit
@testable import TableProEditorKit
import XCTest

final class SuggestionLiveCursorTests: XCTestCase {
    @MainActor
    func test_showCompletions_reranksForTheKeysTypedAfterTheDelegateReadTheEditor() async throws {
        let editor = FocusedEditor(text: "s")
        defer { editor.close() }
        let delegate = ParkingDelegate(answers: ["s": ["set", "select"]], reranked: ["sel": ["select"]])
        let model = SuggestionViewModel()

        var presentations = 0
        model.showCompletions(textView: editor.controller, delegate: delegate, cursorPosition: editor.cursor) { _, _ in
            presentations += 1
        }
        let request = try XCTUnwrap(model.itemsRequestTask)
        await delegate.readTheEditor()

        var closes = 0
        editor.type("e", reportingTo: model, delegate: delegate) { closes += 1 }
        editor.type("l", reportingTo: model, delegate: delegate) { closes += 1 }
        delegate.answer()
        await request.value

        XCTAssertEqual(closes, 0)
        XCTAssertEqual(presentations, 1)
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.items.map(\.label), ["select"])
        XCTAssertEqual(model.selectedItem?.label, "select")
        XCTAssertEqual(delegate.rerankedPrefixes, ["sel"])
    }

    @MainActor
    func test_showCompletions_presentsAnAnswerReadPastTheTriggerAsItCame() async throws {
        let editor = FocusedEditor(text: "u")
        defer { editor.close() }
        let delegate = ParkingDelegate(answers: ["u": ["update", "users"], "": ["id", "name"]], reranked: [:])
        let model = SuggestionViewModel()

        var presentations = 0
        model.showCompletions(textView: editor.controller, delegate: delegate, cursorPosition: editor.cursor) { _, _ in
            presentations += 1
        }
        let request = try XCTUnwrap(model.itemsRequestTask)
        await delegate.untilParked()
        editor.type(".", reportingTo: model, delegate: delegate) {}
        await delegate.readTheEditor()
        delegate.answer()
        await request.value

        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(model.items.map(\.label), ["id", "name"])
        XCTAssertTrue(delegate.rerankedPrefixes.isEmpty)
        XCTAssertEqual(delegate.askedAt, [1])
    }

    @MainActor
    func test_showCompletions_reranksAnEditThatLeftTheCursorWhereItWas() async throws {
        let editor = FocusedEditor(text: "sl")
        defer { editor.close() }
        let delegate = ParkingDelegate(answers: ["sl": ["sleep", "slice"]], reranked: ["se": ["select", "set"]])
        let model = SuggestionViewModel()

        var presentations = 0
        model.showCompletions(textView: editor.controller, delegate: delegate, cursorPosition: editor.cursor) { _, _ in
            presentations += 1
        }
        let request = try XCTUnwrap(model.itemsRequestTask)
        await delegate.readTheEditor()

        editor.deleteBackward(reportingTo: model, delegate: delegate)
        editor.type("e", reportingTo: model, delegate: delegate) {}
        delegate.answer()
        await request.value

        XCTAssertEqual(editor.text, "se")
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(model.items.map(\.label), ["select", "set"])
        XCTAssertEqual(model.selectedItem?.label, "select")
        XCTAssertEqual(delegate.rerankedPrefixes, ["se"])
    }

    @MainActor
    func test_showCompletions_asksAgainWhereATriggerTypedDuringTheRequestLeftTheCursor() async throws {
        let editor = FocusedEditor(text: "u")
        defer { editor.close() }
        let delegate = ParkingDelegate(answers: ["u": ["update", "users"], "": ["id", "name"]], reranked: [:])
        let model = SuggestionViewModel()

        var presentations = 0
        model.showCompletions(textView: editor.controller, delegate: delegate, cursorPosition: editor.cursor) { _, _ in
            presentations += 1
        }
        let request = try XCTUnwrap(model.itemsRequestTask)
        await delegate.readTheEditor()

        editor.type(".", reportingTo: model, delegate: delegate) {}
        delegate.answer()
        await request.value

        let replay = try XCTUnwrap(model.itemsRequestTask)
        XCTAssertEqual(presentations, 0)
        XCTAssertEqual(delegate.didCloseCount, 1)
        await delegate.readTheEditor()
        delegate.answer()
        await replay.value

        XCTAssertEqual(delegate.askedAt, [1, 2])
        XCTAssertEqual(delegate.rerankedPrefixes, [""])
        XCTAssertEqual(presentations, 1)
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.items.map(\.label), ["id", "name"])
    }

    @MainActor
    func test_showCompletions_asksAgainWhenAnAnswerOfNothingMissedAKeyTypedDuringIt() async throws {
        let editor = FocusedEditor(text: "a ")
        defer { editor.close() }
        let delegate = ParkingDelegate(answers: ["d": ["delete", "desc"]], reranked: [:])
        let model = SuggestionViewModel()

        var presentations = 0
        model.showCompletions(textView: editor.controller, delegate: delegate, cursorPosition: editor.cursor) { _, _ in
            presentations += 1
        }
        let request = try XCTUnwrap(model.itemsRequestTask)
        await delegate.readTheEditor()

        editor.type("d", reportingTo: model, delegate: delegate) {}
        delegate.answer()
        await request.value

        let replay = try XCTUnwrap(model.itemsRequestTask)
        await delegate.readTheEditor()
        delegate.answer()
        await replay.value

        XCTAssertEqual(delegate.askedAt, [2, 3])
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(model.items.map(\.label), ["delete", "desc"])
    }

    @MainActor
    func test_showCompletions_endsTheSessionWhenTheLastMoveWhileItWasOutOpensNothing() async throws {
        let editor = FocusedEditor(text: "s")
        defer { editor.close() }
        let delegate = ParkingDelegate(answers: ["s": ["set", "select"]], reranked: [:])
        let model = SuggestionViewModel()

        var presentations = 0
        model.showCompletions(textView: editor.controller, delegate: delegate, cursorPosition: editor.cursor) { _, _ in
            presentations += 1
        }
        let request = try XCTUnwrap(model.itemsRequestTask)
        await delegate.readTheEditor()

        editor.type("x", reportingTo: model, delegate: delegate) {}
        editor.type("-", presentingIfNot: false, reportingTo: model, delegate: delegate) {}
        delegate.answer()
        await request.value

        XCTAssertEqual(presentations, 0)
        XCTAssertFalse(model.isPresented)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.activeTextView)
        XCTAssertNil(model.itemsRequestTask)
        XCTAssertEqual(delegate.didCloseCount, 1)
        XCTAssertEqual(delegate.askedAt, [1])
    }

    @MainActor
    func test_showCompletions_presentsTheAnswerAsItCameWhenTheEditorStillHoldsItsPrefix() async throws {
        let editor = FocusedEditor(text: "u.")
        defer { editor.close() }
        let delegate = ParkingDelegate(answers: ["": ["id", "name"]], reranked: ["": ["unrelated"]])
        let model = SuggestionViewModel()

        var presentations = 0
        model.showCompletions(textView: editor.controller, delegate: delegate, cursorPosition: editor.cursor) { _, _ in
            presentations += 1
        }
        let request = try XCTUnwrap(model.itemsRequestTask)
        await delegate.readTheEditor()
        delegate.answer()
        await request.value

        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(model.items.map(\.label), ["id", "name"])
        XCTAssertTrue(delegate.rerankedPrefixes.isEmpty)
    }

    @MainActor
    func test_typingATriggerWhileTheFirstRequestIsOut_opensTheListForWhereItWasTyped() async throws {
        let (window, controller) = Mock.keyWindowedTextViewController()
        let delegate = ParkingDelegate(
            answers: ["u": ["update", "users"], "": ["id", "name"]],
            reranked: [:],
            triggerCharacters: ["."]
        )
        controller.completionDelegate = delegate
        let suggestions = SuggestionController.shared
        defer {
            suggestions.close()
            window.close()
        }

        controller.textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "u")
        controller.setCursorPositions([CursorPosition(range: NSRange(location: 1, length: 0))])
        let request = try XCTUnwrap(suggestions.model.itemsRequestTask)
        await delegate.readTheEditor()

        controller.textView.replaceCharacters(in: NSRange(location: 1, length: 0), with: ".")
        controller.setCursorPositions([CursorPosition(range: NSRange(location: 2, length: 0))])
        delegate.answer()
        await request.value

        let replay = try XCTUnwrap(suggestions.model.itemsRequestTask)
        await delegate.readTheEditor()
        delegate.answer()
        await replay.value

        XCTAssertEqual(delegate.askedAt, [1, 2])
        XCTAssertTrue(suggestions.model.isPresented)
        XCTAssertIdentical(suggestions.model.activeTextView, controller)
        XCTAssertEqual(suggestions.model.items.map(\.label), ["id", "name"])
    }
}

@MainActor
private struct FocusedEditor {
    let window: NSWindow
    let controller: TextViewController

    init(text: String) {
        (window, controller) = Mock.keyWindowedTextViewController(text: text)
    }

    var text: String { controller.textView.string }

    var cursor: CursorPosition {
        controller.cursorPositions.first ?? CursorPosition(range: NSRange(location: 0, length: 0))
    }

    func type(
        _ character: String,
        presentingIfNot presentIfNot: Bool = true,
        reportingTo model: SuggestionViewModel,
        delegate: CodeSuggestionDelegate,
        close: () -> Void
    ) {
        let location = cursor.range.location
        controller.textView.replaceCharacters(in: NSRange(location: location, length: 0), with: character)
        moveCursor(to: location + (character as NSString).length)
        model.cursorsUpdated(
            textView: controller,
            delegate: delegate,
            position: cursor,
            presentIfNot: presentIfNot,
            close: close
        )
    }

    func deleteBackward(reportingTo model: SuggestionViewModel, delegate: CodeSuggestionDelegate) {
        let location = cursor.range.location - 1
        controller.textView.replaceCharacters(in: NSRange(location: location, length: 1), with: "")
        moveCursor(to: location)
        model.cursorsUpdated(textView: controller, delegate: delegate, position: cursor) {}
    }

    func close() {
        window.close()
    }

    private func moveCursor(to location: Int) {
        controller.setCursorPositions([CursorPosition(range: NSRange(location: location, length: 0))])
    }
}

@MainActor
private final class ParkingDelegate: CodeSuggestionDelegate {
    private let answers: [String: [String]]
    private let reranked: [String: [String]]
    private let triggerCharacters: Set<String>
    private var parked: CheckedContinuation<Void, Never>?
    private var parkingWaiter: CheckedContinuation<Void, Never>?
    private(set) var askedAt: [Int] = []
    private(set) var rerankedPrefixes: [String] = []
    private(set) var didCloseCount = 0

    init(answers: [String: [String]], reranked: [String: [String]], triggerCharacters: Set<String> = []) {
        self.answers = answers
        self.reranked = reranked
        self.triggerCharacters = triggerCharacters
    }

    func untilParked() async {
        guard parked == nil else { return }
        await withCheckedContinuation { continuation in
            parkingWaiter = continuation
        }
    }

    func readTheEditor() async {
        await untilParked()
        resume()
        await untilParked()
    }

    func answer() {
        resume()
    }

    func completionTriggerCharacters() -> Set<String> {
        triggerCharacters
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition,
        isManualTrigger: Bool
    ) async -> CodeSuggestionResponse? {
        askedAt.append(cursorPosition.range.location)
        await park()
        let cursor = textView.cursorPositions.first ?? cursorPosition
        let prefix = Self.prefix(in: textView, endingAt: cursor.range.location)
        await park()
        guard let labels = answers[prefix.text] else { return nil }
        return CodeSuggestionResponse(
            items: labels.map { StubSuggestionEntry(label: $0) },
            windowPosition: cursor,
            prefix: prefix
        )
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        let prefix = Self.prefix(in: textView, endingAt: cursorPosition.range.location)
        rerankedPrefixes.append(prefix.text)
        return reranked[prefix.text]?.map { StubSuggestionEntry(label: $0) }
    }

    func completionWindowDidClose() {
        didCloseCount += 1
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {}

    private func park() async {
        await withCheckedContinuation { continuation in
            parked = continuation
            parkingWaiter?.resume()
            parkingWaiter = nil
        }
    }

    private func resume() {
        let continuation = parked
        parked = nil
        continuation?.resume()
    }

    private static func prefix(in textView: TextViewController, endingAt location: Int) -> CodeSuggestionPrefix {
        let text = textView.textView.string as NSString
        var start = location
        while start > 0, let scalar = UnicodeScalar(text.character(at: start - 1)),
              CharacterSet.letters.contains(scalar) {
            start -= 1
        }
        let range = NSRange(location: start, length: location - start)
        return CodeSuggestionPrefix(range: range, text: text.substring(with: range))
    }
}
