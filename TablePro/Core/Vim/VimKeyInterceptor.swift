//
//  VimKeyInterceptor.swift
//  TablePro
//
//  Intercepts key events for Vim mode via NSEvent local monitor
//

@preconcurrency import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import os

/// Which window a key event seen by the app-wide monitor belongs to
enum VimKeyEventScope: Equatable {
    case editorText
    case editorAuxiliary
    case foreign
}

/// Every editor tab is its own window and each one installs an app-wide key monitor,
/// so an event belongs to an interceptor only while that editor's own window tree
/// holds key focus. Without the key check a background editor consumes Escape for the
/// whole app.
enum VimKeyEventScopeResolver {
    static func scope(
        eventWindowIsEditorWindow: Bool,
        eventWindowIsEditorDescendant: Bool,
        eventWindowIsAbsent: Bool,
        editorWindowTreeIsKey: Bool
    ) -> VimKeyEventScope {
        guard editorWindowTreeIsKey else { return .foreign }
        if eventWindowIsEditorWindow { return .editorText }
        guard eventWindowIsEditorDescendant || eventWindowIsAbsent else { return .foreign }
        return .editorAuxiliary
    }
}

/// Intercepts keyboard events and routes them through the Vim engine
@MainActor
final class VimKeyInterceptor {
    private let engine: VimEngine
    private weak var inlineSuggestionManager: InlineSuggestionManager?
    private let _monitor = OSAllocatedUnfairLock<Any?>(uncheckedState: nil)
    private weak var controller: TextViewController?
    private let _popupCloseObserver = OSAllocatedUnfairLock<Any?>(uncheckedState: nil)
    private let _keyWindowObservers = OSAllocatedUnfairLock<[Any]>(uncheckedState: [])
    private var isEditorFirstResponder = false
    private(set) var isEditorFocused = false

    deinit {
        if let monitor = _monitor.withLockUnchecked({ $0 }) { NSEvent.removeMonitor(monitor) }
        if let observer = _popupCloseObserver.withLockUnchecked({ $0 }) { NotificationCenter.default.removeObserver(observer) }
        for observer in _keyWindowObservers.withLockUnchecked({ $0 }) { NotificationCenter.default.removeObserver(observer) }
    }

    init(engine: VimEngine, inlineSuggestionManager: InlineSuggestionManager?) {
        self.engine = engine
        self.inlineSuggestionManager = inlineSuggestionManager
    }

    /// Install the interceptor on a controller (does not install the event monitor until editor is focused)
    func install(controller: TextViewController) {
        self.controller = controller
        uninstall()

        _popupCloseObserver.withLockUnchecked { $0 = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Capture the triggering event synchronously — NSApp.currentEvent rotates
            // out by the time any deferred work runs, so reading it later returns nil
            // or a stale event and the popup-close path silently no-ops.
            let triggeringEvent = NSApp.currentEvent
            MainActor.assumeIsolated {
                guard let self,
                      let closingWindow = notification.object as? NSWindow,
                      closingWindow.windowController is SuggestionController,
                      let editorWindow = self.controller?.textView?.window,
                      editorWindow.childWindows?.contains(closingWindow) == true,
                      let currentEvent = triggeringEvent,
                      currentEvent.type == .keyDown,
                      currentEvent.keyCode == 53,
                      self.engine.mode != .normal else {
                    return
                }
                self.inlineSuggestionManager?.dismissSuggestion()
                _ = self.engine.process("\u{1B}", shift: false)
            }
        }
        }

        installKeyWindowObservers()
    }

    func editorDidFocus() {
        guard !isEditorFirstResponder else { return }
        isEditorFirstResponder = true
        refreshFocusState()
    }

    func editorDidBlur() {
        guard isEditorFirstResponder else { return }
        isEditorFirstResponder = false
        refreshFocusState()
    }

    /// Route an Escape press from outside the local event monitor (e.g. a SwiftUI menu
    /// key equivalent that preempts the event before the monitor fires). Returns true
    /// when the engine was in a non-normal mode and consumed the escape.
    @discardableResult
    func handleEscapeFromExternalSource() -> Bool {
        guard engine.mode != .normal else { return false }
        inlineSuggestionManager?.dismissSuggestion()
        closeSuggestionPopup()
        _ = engine.process("\u{1B}", shift: false)
        return true
    }

    /// Remove all monitors and observers
    func uninstall() {
        isEditorFirstResponder = false
        isEditorFocused = false
        removeMonitor()
        _popupCloseObserver.withLockUnchecked {
            if let observer = $0 { NotificationCenter.default.removeObserver(observer) }
            $0 = nil
        }
        _keyWindowObservers.withLockUnchecked {
            for observer in $0 { NotificationCenter.default.removeObserver(observer) }
            $0 = []
        }
    }

    // MARK: - Focus State

    private func installKeyWindowObservers() {
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
        let observers: [Any] = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshFocusState()
                }
            }
        }
        _keyWindowObservers.withLockUnchecked { $0 = observers }
    }

    private func refreshFocusState() {
        let focused = isEditorFirstResponder && editorWindowTreeIsKey()
        guard focused != isEditorFocused else { return }
        isEditorFocused = focused
        if focused {
            installMonitor()
            return
        }
        removeMonitor()
    }

    /// A text view with no window cannot receive key events at all, so focus tracking
    /// stays driven by the first responder until the editor is mounted.
    private func editorWindowTreeIsKey() -> Bool {
        guard let editorWindow = controller?.textView?.window else { return true }
        if editorWindow.isKeyWindow { return true }
        guard let keyWindow = NSApp.keyWindow else { return false }
        return isDescendant(keyWindow, of: editorWindow)
    }

    private func isDescendant(_ window: NSWindow?, of editorWindow: NSWindow) -> Bool {
        var parent = window?.parent
        while let current = parent {
            if current === editorWindow { return true }
            parent = current.parent
        }
        return false
    }

    private func installMonitor() {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] nsEvent in
            nonisolated(unsafe) let event = nsEvent
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isEditorFocused else { return false }
                return self.handleKeyEvent(event) == nil
            }
            return consumed ? nil : nsEvent
        }
        _monitor.withLockUnchecked { $0 = monitor }
    }

    private func removeMonitor() {
        _monitor.withLockUnchecked {
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
        guard let textView = controller?.textView,
              let editorWindow = textView.window else {
            return event
        }

        // An input method owns the keystroke while it has marked text. Acting on Escape
        // here would cancel Vim's insert mode and strand the composition, so every key
        // goes to the input context until the marking session ends.
        guard !textView.hasMarkedText() else { return event }

        let scope = VimKeyEventScopeResolver.scope(
            eventWindowIsEditorWindow: event.window === editorWindow,
            eventWindowIsEditorDescendant: isDescendant(event.window, of: editorWindow),
            eventWindowIsAbsent: event.window == nil,
            editorWindowTreeIsKey: editorWindowTreeIsKey()
        )
        guard scope != .foreign else { return event }

        // Esc still has to reach the engine when the event carries no window (synthesized)
        // or belongs to an autocomplete popup owned by this editor, otherwise Vim stays
        // stuck in insert (symptom: Esc right after typing ';' at the end of the buffer).
        if event.keyCode == 53, engine.mode != .normal {
            inlineSuggestionManager?.dismissSuggestion()
            closeSuggestionPopup()
            _ = engine.process("\u{1B}", shift: false)
            return nil
        }

        guard scope == .editorText, editorWindow.firstResponder === textView else {
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

        let shift = modifiers.contains(.shift)
        let consumed = engine.process(char, shift: shift)

        return consumed ? nil : event
    }

    private func closeSuggestionPopup() {
        controller?.dismissCompletions()
    }
}
