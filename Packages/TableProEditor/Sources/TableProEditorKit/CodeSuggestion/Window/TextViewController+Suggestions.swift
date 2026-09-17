//
//  TextViewController+Suggestions.swift
//  TableProEditorKit
//

import AppKit

public extension TextViewController {
    /// Whether the completion popup is currently showing for this controller.
    var isShowingCompletions: Bool {
        SuggestionController.shared.model.isPresented && SuggestionController.shared.model.activeTextView === self
    }

    /// Ends this controller's completion session and reports whether a popup was on screen to
    /// dismiss.
    ///
    /// The two are separate answers on purpose. Escape and the Ctrl+Space toggle both read the
    /// return value to decide between dismissing and opening, so a session that never got a
    /// window must report `false` and still be ended: gating the close on visibility left the
    /// only two keys that could clear it doing nothing at all.
    @discardableResult
    func dismissCompletions() -> Bool {
        let controller = SuggestionController.shared
        guard controller.model.activeTextView === self else { return false }
        let wasShowing = controller.model.isPresented
        controller.close()
        return wasShowing
    }
}
