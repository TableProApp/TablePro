//
//  VimKeyInterceptor.swift
//  TablePro
//
//  Routes key events to the Vim engine from the editor's single key-down chain
//

import AppKit
import os
import TableProEditorKit
import TableProTextEngine

/// Hands keys to the Vim engine before the editor's own key handling sees them.
///
/// It owns no event monitor. The editor has exactly one, and everything that wants a key first is
/// consulted from `TextViewController.dispatchKeyDown(_:)` in a fixed order, because
/// `NSEvent.addLocalMonitorForEvents` orders same-mask monitors arbitrarily.
@MainActor
final class VimKeyInterceptor {
    private let engine: VimEngine
    private weak var inlineSuggestionManager: InlineSuggestionManager?
    private weak var controller: TextViewController?

    init(engine: VimEngine, inlineSuggestionManager: InlineSuggestionManager?) {
        self.engine = engine
        self.inlineSuggestionManager = inlineSuggestionManager
    }

    func install(controller: TextViewController) {
        self.controller = controller
    }

    func uninstall() {
        controller = nil
    }

    /// Route an Escape press that arrived from outside the key chain, which is the Edit menu's
    /// Clear Selection item when it is clicked with the pointer. Returns whether the engine was in
    /// a non-normal mode and consumed it.
    @discardableResult
    func handleEscapeFromExternalSource() -> Bool {
        guard engine.mode != .normal else { return false }
        dismissSuggestionSurfaces()
        _ = engine.process("\u{1B}", shift: false)
        return true
    }

    // MARK: - Key Handling

    /// Returns nil to claim the event, or the event to leave it to the rest of the chain.
    ///
    /// The caller has already established that this editor's window is key and that its text view
    /// holds first responder, so there is no window scoping to do here.
    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let textView = controller?.textView else { return event }

        // An input method owns the keystroke while it has marked text. Acting on Escape here would
        // cancel Vim's insert mode and strand the composition, so every key goes to the input
        // context until the marking session ends.
        guard !textView.hasMarkedText() else { return event }

        if event.keyCode == 53, engine.mode != .normal {
            dismissSuggestionSurfaces()
            _ = engine.process("\u{1B}", shift: false)
            return nil
        }

        let keystroke = VimKeystroke(
            characters: event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            modifiers: event.modifierFlags,
            isKeypadEnter: event.semanticKeyCode == .enter
        )
        switch VimKeyRouteResolver.route(keystroke, in: engine.mode) {
        case .textView:
            return event
        case .discard:
            return nil
        case .engine(let character):
            return process(character, shift: keystroke.modifiers.contains(.shift)) ? nil : event
        }
    }

    private func process(_ character: Character, shift: Bool) -> Bool {
        if character == "\u{1B}", engine.mode != .normal {
            dismissSuggestionSurfaces()
        }
        return engine.process(character, shift: shift)
    }

    /// One Escape leaves Insert mode and takes both suggestion surfaces with it, rather than asking
    /// for a second press, which is what Xcode and IdeaVim do.
    private func dismissSuggestionSurfaces() {
        inlineSuggestionManager?.dismissSuggestion()
        controller?.dismissCompletions()
    }
}
