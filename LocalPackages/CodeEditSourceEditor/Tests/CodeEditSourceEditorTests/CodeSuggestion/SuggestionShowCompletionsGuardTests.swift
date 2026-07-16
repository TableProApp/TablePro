import AppKit
@testable import CodeEditSourceEditor
import SwiftUI
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
        let delegate = DelayedStubDelegate(items: [GuardStubEntry(label: "SELECT")])

        var presentationCount = 0
        model.showCompletions(
            textView: textViewController,
            delegate: delegate,
            cursorPosition: CursorPosition(range: NSRange(location: 0, length: 0))
        ) { _, _ in
            presentationCount += 1
        }

        window.makeFirstResponder(nil)
        await model.itemsRequestTask?.value

        XCTAssertEqual(presentationCount, 0)
    }

    @MainActor
    func test_showCompletions_presentsWhenEditorStillFocused() async throws {
        let (window, textViewController) = Mock.windowedTextViewController(theme: Mock.theme())
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        guard window.isKeyWindow else {
            throw XCTSkip("Window cannot become key in this environment")
        }

        let textView = try XCTUnwrap(textViewController.textView)
        XCTAssertTrue(window.makeFirstResponder(textView))

        let model = SuggestionViewModel()
        let delegate = DelayedStubDelegate(items: [GuardStubEntry(label: "SELECT")])

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
        XCTAssertTrue(presentedWindows.first === window)
    }
}

@MainActor
private final class DelayedStubDelegate: CodeSuggestionDelegate {
    let items: [CodeSuggestionEntry]

    init(items: [CodeSuggestionEntry]) {
        self.items = items
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition,
        isManualTrigger: Bool
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        try? await Task.sleep(for: .milliseconds(50))
        return (windowPosition: cursorPosition, items: items)
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        nil
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {}
}

private struct GuardStubEntry: CodeSuggestionEntry {
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
