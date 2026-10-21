//
//  EmacsKeyInterceptor.swift
//  TablePro
//

import AppKit
import TableProEditorKit
import TableProTextEngine

// Consulted from the editor's one key-down chain at the link Vim mode uses, so the two never both see a key.
@MainActor
final class EmacsKeyInterceptor {
    private let engine = EmacsEngine()
    private weak var inlineSuggestionManager: InlineSuggestionManager?
    private weak var controller: TextViewController?

    init(inlineSuggestionManager: InlineSuggestionManager?) {
        self.inlineSuggestionManager = inlineSuggestionManager
    }

    func install(controller: TextViewController) {
        self.controller = controller
    }

    func uninstall() {
        controller = nil
    }

    // Returns nil to claim the event.
    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let controller, let textView = controller.textView else { return event }
        // An input method owns every key while it has marked text.
        guard !textView.hasMarkedText() else { return event }

        // The arrows stay with an open completion list.
        let extendsRegion = engine.isMarkActive(in: textView) && !controller.isShowingCompletions
        guard let command = EmacsKeyResolver.command(
            for: EmacsKeystroke(event: event),
            markActive: extendsRegion
        ) else { return event }

        if command == .quit {
            inlineSuggestionManager?.dismissSuggestion()
            controller.dismissCompletions()
        }
        engine.perform(command, in: textView)
        return nil
    }
}
