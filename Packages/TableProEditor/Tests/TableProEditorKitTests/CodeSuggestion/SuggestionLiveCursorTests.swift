import AppKit
import SwiftUI
@testable import TableProEditorKit
import XCTest

final class SuggestionLiveCursorTests: XCTestCase {
    @MainActor
    func test_showCompletions_ranksForTheKeysTypedWhileTheRequestWasOut() async throws {
        let editor = try FocusedEditor(text: "s")
        defer { editor.close() }
        let delegate = GatedDelegate(
            requested: [LiveCursorStubEntry(label: "set"), LiveCursorStubEntry(label: "select")],
            rankedAt: [3: [LiveCursorStubEntry(label: "select")]]
        )
        let model = SuggestionViewModel()

        var presentations = 0
        model.showCompletions(
            textView: editor.controller,
            delegate: delegate,
            cursorPosition: CursorPosition(range: NSRange(location: 1, length: 0))
        ) { _, _ in presentations += 1 }
        let request = try XCTUnwrap(model.itemsRequestTask)
        await delegate.untilAsked()

        var closes = 0
        editor.type("e", at: 1)
        model.cursorsUpdated(textView: editor.controller, delegate: delegate, position: editor.cursor) { closes += 1 }
        editor.type("l", at: 2)
        model.cursorsUpdated(textView: editor.controller, delegate: delegate, position: editor.cursor) { closes += 1 }

        delegate.answer()
        await request.value

        XCTAssertEqual(closes, 0)
        XCTAssertEqual(presentations, 1)
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.items.map(\.label), ["select"])
        XCTAssertEqual(model.selectedItem?.label, "select")
        XCTAssertEqual(delegate.rankedPositions, [3])
    }

    @MainActor
    func test_showCompletions_endsTheSessionWhenNothingMatchesWhereTheCursorMoved() async throws {
        let editor = try FocusedEditor(text: "s")
        defer { editor.close() }
        let delegate = GatedDelegate(
            requested: [LiveCursorStubEntry(label: "set"), LiveCursorStubEntry(label: "select")],
            rankedAt: [:]
        )
        let model = SuggestionViewModel()

        var presentations = 0
        model.showCompletions(
            textView: editor.controller,
            delegate: delegate,
            cursorPosition: CursorPosition(range: NSRange(location: 1, length: 0))
        ) { _, _ in presentations += 1 }
        let request = try XCTUnwrap(model.itemsRequestTask)
        await delegate.untilAsked()

        editor.type("x", at: 1)
        model.cursorsUpdated(textView: editor.controller, delegate: delegate, position: editor.cursor) {}

        delegate.answer()
        await request.value

        XCTAssertEqual(presentations, 0)
        XCTAssertFalse(model.isPresented)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.activeTextView)
        XCTAssertEqual(delegate.didCloseCount, 1)
    }

    @MainActor
    func test_showCompletions_presentsTheAnswerAsIsWhenTheCursorStayedPut() async throws {
        let editor = try FocusedEditor(text: "u.")
        defer { editor.close() }
        let delegate = GatedDelegate(
            requested: [LiveCursorStubEntry(label: "id"), LiveCursorStubEntry(label: "name")],
            rankedAt: [2: [LiveCursorStubEntry(label: "unrelated")]]
        )
        let model = SuggestionViewModel()

        var presentations = 0
        model.showCompletions(
            textView: editor.controller,
            delegate: delegate,
            cursorPosition: CursorPosition(range: NSRange(location: 2, length: 0))
        ) { _, _ in presentations += 1 }
        let request = try XCTUnwrap(model.itemsRequestTask)
        await delegate.untilAsked()

        delegate.answer()
        await request.value

        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(model.items.map(\.label), ["id", "name"])
        XCTAssertTrue(delegate.rankedPositions.isEmpty)
    }
}

@MainActor
private struct FocusedEditor {
    let window: NSWindow
    let controller: TextViewController

    init(text: String) throws {
        controller = Mock.textViewController(theme: Mock.theme())
        window = LiveCursorKeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFrontRegardless()
        controller.textView.setText(text)
        controller.view.layoutSubtreeIfNeeded()
        let end = (text as NSString).length
        controller.setCursorPositions([CursorPosition(range: NSRange(location: end, length: 0))])
        XCTAssertTrue(window.makeFirstResponder(controller.textView))
    }

    var cursor: CursorPosition {
        controller.cursorPositions.first ?? CursorPosition(range: NSRange(location: 0, length: 0))
    }

    func type(_ character: String, at location: Int) {
        controller.textView.replaceCharacters(in: NSRange(location: location, length: 0), with: character)
        let end = location + (character as NSString).length
        controller.setCursorPositions([CursorPosition(range: NSRange(location: end, length: 0))])
    }

    func close() {
        window.close()
    }
}

private final class LiveCursorKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor
private final class GatedDelegate: CodeSuggestionDelegate {
    private let requested: [CodeSuggestionEntry]
    private let rankedAt: [Int: [CodeSuggestionEntry]]
    private let asked: AsyncStream<Void>
    private let askedContinuation: AsyncStream<Void>.Continuation
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var rankedPositions: [Int] = []
    private(set) var didCloseCount = 0

    init(requested: [CodeSuggestionEntry], rankedAt: [Int: [CodeSuggestionEntry]]) {
        self.requested = requested
        self.rankedAt = rankedAt
        (asked, askedContinuation) = AsyncStream<Void>.makeStream()
    }

    func untilAsked() async {
        for await _ in asked {
            break
        }
    }

    func answer() {
        gate?.resume()
        gate = nil
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition,
        isManualTrigger: Bool
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        await withCheckedContinuation { continuation in
            gate = continuation
            askedContinuation.yield()
        }
        return (windowPosition: cursorPosition, items: requested)
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        rankedPositions.append(cursorPosition.range.location)
        return rankedAt[cursorPosition.range.location]
    }

    func completionWindowDidClose() {
        didCloseCount += 1
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {}
}

private struct LiveCursorStubEntry: CodeSuggestionEntry {
    var label: String
    var detail: String? { nil }
    var documentation: String? { nil }
    var pathComponents: [String]? { nil }
    var targetPosition: CursorPosition? { nil }
    var sourcePreview: String? { nil }
    var image: Image { Image(systemName: "circle") }
    var imageColor: Color { .gray }
    var deprecated: Bool { false }
}
