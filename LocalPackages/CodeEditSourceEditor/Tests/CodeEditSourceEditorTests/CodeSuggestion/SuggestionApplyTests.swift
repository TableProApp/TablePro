import AppKit
@testable import CodeEditSourceEditor
import SwiftUI
import XCTest

final class SuggestionApplyTests: XCTestCase {
    @MainActor
    func test_apply_invokesOnApplyCallback() throws {
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

        XCTAssertEqual(onApplyCount, 1)
        XCTAssertEqual(delegate.applyCallCount, 1)
    }

    @MainActor
    func test_apply_skipsCallbackWhenActiveTextViewIsNil() throws {
        let model = SuggestionViewModel()
        let delegate = StubSuggestionDelegate()
        let item = StubSuggestionEntry(label: "users")

        model.delegate = delegate
        model.items = [item]

        var onApplyCount = 0
        model.onApply = { onApplyCount += 1 }

        model.applySelectedItem(item: item)

        XCTAssertEqual(onApplyCount, 0)
        XCTAssertEqual(delegate.applyCallCount, 0)
    }

    @MainActor
    func test_nsWindowClose_clearsModelState() throws {
        let controller = SuggestionController()
        let textViewController = Mock.textViewController(theme: Mock.theme())

        controller.model.activeTextView = textViewController
        controller.model.delegate = StubSuggestionDelegate()
        controller.model.items = [StubSuggestionEntry(label: "users")]
        controller.model.selectedIndex = 0

        controller.window?.close()

        XCTAssertNil(controller.model.activeTextView)
        XCTAssertTrue(controller.model.items.isEmpty)
    }

    @MainActor
    func test_controllerClose_clearsModelState() throws {
        let controller = SuggestionController()
        let textViewController = Mock.textViewController(theme: Mock.theme())

        controller.model.activeTextView = textViewController
        controller.model.delegate = StubSuggestionDelegate()
        controller.model.items = [StubSuggestionEntry(label: "users")]
        controller.model.selectedIndex = 0

        controller.close()

        XCTAssertNil(controller.model.activeTextView)
        XCTAssertTrue(controller.model.items.isEmpty)
    }
}

private final class StubSuggestionDelegate: CodeSuggestionDelegate {
    var applyCallCount = 0

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition,
        isManualTrigger: Bool
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        nil
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
    ) {
        applyCallCount += 1
    }
}

private struct StubSuggestionEntry: CodeSuggestionEntry {
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
