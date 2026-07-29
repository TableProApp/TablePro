//
//  TextViewController+Suggestions.swift
//  CodeEditSourceEditor
//

import AppKit

public extension TextViewController {
    /// Whether the completion popup is currently showing for this controller.
    var isShowingCompletions: Bool {
        SuggestionController.shared.isVisible && SuggestionController.shared.model.activeTextView === self
    }

    /// Dismisses the completion popup when it is showing for this controller.
    /// Returns whether a popup was dismissed.
    @discardableResult
    func dismissCompletions() -> Bool {
        guard isShowingCompletions else { return false }
        SuggestionController.shared.close()
        return true
    }
}
