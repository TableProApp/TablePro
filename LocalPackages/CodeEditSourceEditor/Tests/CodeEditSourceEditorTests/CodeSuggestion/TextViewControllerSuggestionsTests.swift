import AppKit
@testable import CodeEditSourceEditor
import XCTest

final class TextViewControllerSuggestionsTests: XCTestCase {
    @MainActor
    func test_isShowingCompletions_falseWhenNothingShowing() {
        let controller = Mock.textViewController(theme: Mock.theme())
        defer { resetSharedSuggestions() }

        XCTAssertFalse(controller.isShowingCompletions)
    }

    @MainActor
    func test_dismissCompletions_returnsFalseWhenNothingShowing() {
        let controller = Mock.textViewController(theme: Mock.theme())
        defer { resetSharedSuggestions() }

        XCTAssertFalse(controller.dismissCompletions())
    }

    @MainActor
    func test_isShowingCompletions_trueOnlyForOwningController() {
        let owner = Mock.textViewController(theme: Mock.theme())
        let other = Mock.textViewController(theme: Mock.theme())
        defer { resetSharedSuggestions() }

        SuggestionController.shared.model.activeTextView = owner
        SuggestionController.shared.window?.orderFrontRegardless()

        XCTAssertTrue(owner.isShowingCompletions)
        XCTAssertFalse(other.isShowingCompletions)
    }

    @MainActor
    func test_dismissCompletions_closesPopupAndReturnsTrueWhenVisible() {
        let owner = Mock.textViewController(theme: Mock.theme())
        defer { resetSharedSuggestions() }

        SuggestionController.shared.model.activeTextView = owner
        SuggestionController.shared.window?.orderFrontRegardless()
        XCTAssertTrue(owner.isShowingCompletions)

        let dismissed = owner.dismissCompletions()

        XCTAssertTrue(dismissed)
        XCTAssertFalse(SuggestionController.shared.isVisible)
        XCTAssertFalse(owner.isShowingCompletions)
    }

    @MainActor
    private func resetSharedSuggestions() {
        SuggestionController.shared.close()
        SuggestionController.shared.model.activeTextView = nil
    }
}
