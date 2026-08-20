import AppKit
@testable import CodeEditSourceEditor
import SwiftUI
import XCTest

final class SuggestionCursorsUpdatedTests: XCTestCase {
    @MainActor
    func test_cursorsUpdated_keepsWindowOpenWhileRequestIsInFlight() throws {
        let model = SuggestionViewModel()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let delegate = FilteringStubDelegate(itemsOnCursorMove: nil)

        model.activeTextView = textViewController
        model.delegate = delegate
        model.items = [FilterStubEntry(label: "SELECT")]
        model.itemsRequestTask = Task { try? await Task.sleep(for: .seconds(10)) }
        defer { model.itemsRequestTask?.cancel() }

        var closeCount = 0
        model.cursorsUpdated(
            textView: textViewController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 1, length: 0))
        ) { closeCount += 1 }

        XCTAssertEqual(closeCount, 0)
        XCTAssertNotNil(model.itemsRequestTask)
    }

    @MainActor
    func test_cursorsUpdated_filtersItemsInPlaceWhenDelegateProvidesThem() throws {
        let model = SuggestionViewModel()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let filtered: [CodeSuggestionEntry] = [FilterStubEntry(label: "SELECT"), FilterStubEntry(label: "SET")]
        let delegate = FilteringStubDelegate(itemsOnCursorMove: filtered)

        model.activeTextView = textViewController
        model.delegate = delegate
        model.items = [FilterStubEntry(label: "stale")]
        model.selectedIndex = 0

        var closeCount = 0
        model.cursorsUpdated(
            textView: textViewController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 2, length: 0))
        ) { closeCount += 1 }

        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(model.items.map(\.label), ["SELECT", "SET"])
        XCTAssertEqual(model.selectedIndex, 0)
    }

    @MainActor
    func test_cursorsUpdated_closesWhenNoItemsAndNoRequestInFlight() throws {
        let model = SuggestionViewModel()
        let textViewController = Mock.textViewController(theme: Mock.theme())
        let delegate = FilteringStubDelegate(itemsOnCursorMove: nil)

        model.activeTextView = textViewController
        model.delegate = delegate
        model.items = [FilterStubEntry(label: "SELECT")]
        model.itemsRequestTask = nil

        var closeCount = 0
        model.cursorsUpdated(
            textView: textViewController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 0, length: 0))
        ) { closeCount += 1 }

        XCTAssertEqual(closeCount, 1)
    }

    @MainActor
    func test_cursorsUpdated_cancelsRequestAndClosesForDifferentTextView() throws {
        let model = SuggestionViewModel()
        let activeController = Mock.textViewController(theme: Mock.theme())
        let otherController = Mock.textViewController(theme: Mock.theme())
        let delegate = FilteringStubDelegate(itemsOnCursorMove: [FilterStubEntry(label: "SELECT")])

        model.activeTextView = activeController
        model.delegate = delegate
        model.itemsRequestTask = Task { try? await Task.sleep(for: .seconds(10)) }

        var closeCount = 0
        model.cursorsUpdated(
            textView: otherController,
            delegate: delegate,
            position: CursorPosition(range: NSRange(location: 0, length: 0))
        ) { closeCount += 1 }

        XCTAssertEqual(closeCount, 1)
        XCTAssertNil(model.itemsRequestTask)
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
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
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

private struct FilterStubEntry: CodeSuggestionEntry {
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
