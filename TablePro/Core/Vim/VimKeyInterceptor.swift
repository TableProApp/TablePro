//
//  VimKeyInterceptor.swift
//  TablePro
//
//  Intercepts key events for Vim mode via NSEvent local monitor
//

@preconcurrency import AppKit
import os

/// Intercepts keyboard events and routes them through the Vim engine
@MainActor
final class VimKeyInterceptor {
    private let engine: VimEngine
    private weak var inlineSuggestionManager: InlineSuggestionManager?
    private let _monitor = OSAllocatedUnfairLock<Any?>(initialState: nil)
    private weak var textView: NSTextView?
    private let _popupCloseObserver = OSAllocatedUnfairLock<Any?>(initialState: nil)
    private(set) var isEditorFocused = false

    deinit {
        if let monitor = _monitor.withLock({ $0 }) { NSEvent.removeMonitor(monitor) }
        if let observer = _popupCloseObserver.withLock({ $0 }) { NotificationCenter.default.removeObserver(observer) }
    }

    init(engine: VimEngine, inlineSuggestionManager: InlineSuggestionManager?) {
        self.engine = engine
        self.inlineSuggestionManager = inlineSuggestionManager
    }

    /// Install the interceptor on a text view (does not install the event monitor until editor is focused)
    func install(textView: NSTextView) {
        self.textView = textView
        uninstall()

        // TODO: Wire to TPCompletionController
    }

    func editorDidFocus() {
        guard !isEditorFocused else { return }
        isEditorFocused = true
        installMonitor()
    }

    func editorDidBlur() {
        guard isEditorFocused else { return }
        isEditorFocused = false
        removeMonitor()
    }

    /// Remove all monitors and observers
    func uninstall() {
        isEditorFocused = false
        removeMonitor()
        _popupCloseObserver.withLock {
            if let observer = $0 { NotificationCenter.default.removeObserver(observer) }
            $0 = nil
        }
    }

    private func installMonitor() {
        _monitor.withLock {
            $0 = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] nsEvent in
                nonisolated(unsafe) let event = nsEvent
                return MainActor.assumeIsolated {
                    guard let self, self.isEditorFocused else { return event }
                    return self.handleKeyEvent(event)
                }
            }
        }
    }

    private func removeMonitor() {
        _monitor.withLock {
            if let monitor = $0 { NSEvent.removeMonitor(monitor) }
            $0 = nil
        }
    }

    /// Arrow key Unicode scalars → Vim motion characters
    private static let arrowToVimKey: [UInt32: Character] = [
        0xF700: "k", // Up
        0xF701: "j", // Down
        0xF702: "h", // Left
        0xF703: "l"  // Right
    ]

    // MARK: - Event Handling

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard let textView,
              event.window === textView.window,
              textView.window?.firstResponder === textView else {
            return event
        }

        // Pass through all events with Cmd or Option modifiers
        // (system shortcuts like Cmd+C, Cmd+V, Cmd+Z, etc.)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.option) {
            return event
        }

        // Ctrl+R in Normal mode → redo (Vim convention)
        if modifiers.contains(.control) {
            if !engine.mode.isInsert && event.keyCode == 15 { // keyCode 15 = R
                engine.redo()
                return nil
            }
            return event // Pass through other Ctrl combinations
        }

        // Translate NSEvent to Character
        guard let characters = event.characters, let char = characters.first else {
            return event
        }

        // In non-insert modes, translate arrow keys to h/j/k/l so the Vim engine
        // handles them (critical for visual mode selection to work with arrows).
        if let scalar = char.unicodeScalars.first, scalar.value >= 0xF700 {
            if !engine.mode.isInsert, let vimChar = Self.arrowToVimKey[scalar.value] {
                let consumed = engine.process(vimChar, shift: modifiers.contains(.shift))
                return consumed ? nil : event
            }
            return event // Pass through non-arrow function keys and insert-mode arrows
        }

        // In non-normal modes, Escape should exit to Normal mode.
        // Also dismiss any active inline suggestion and close autocomplete popup.
        if engine.mode != .normal && char == "\u{1B}" {
            inlineSuggestionManager?.dismissSuggestion()
            closeSuggestionPopup()
        }

        // Feed to Vim engine
        let shift = modifiers.contains(.shift)
        let consumed = engine.process(char, shift: shift)

        return consumed ? nil : event
    }

    private func closeSuggestionPopup() {
        // TODO: Wire to TPCompletionController
    }
}
