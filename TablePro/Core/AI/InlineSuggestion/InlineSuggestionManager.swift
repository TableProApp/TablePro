//
//  InlineSuggestionManager.swift
//  TablePro
//

@preconcurrency import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import os

@MainActor
final class InlineSuggestionManager {
    // MARK: - Properties

    private static let logger = Logger(subsystem: "com.TablePro", category: "InlineSuggestion")

    private weak var controller: TextViewController?
    private let renderer = GhostTextRenderer()
    private var sourceResolver: (@MainActor () -> InlineSuggestionSource?)?
    private var currentSuggestion: InlineSuggestion?
    private var suggestionOffset: Int = 0
    private var debounceTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private let _keyEventMonitor = OSAllocatedUnfairLock<Any?>(initialState: nil)
    private(set) var isEditorFocused = false
    private var isUninstalled = false

    deinit {
        if let monitor = _keyEventMonitor.withLock({ $0 }) { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - Install / Uninstall

    func install(
        controller: TextViewController,
        sourceResolver: @escaping @MainActor () -> InlineSuggestionSource?
    ) {
        self.controller = controller
        self.sourceResolver = sourceResolver
        renderer.install(controller: controller)
    }

    func editorDidFocus() {
        guard !isEditorFocused else { return }
        isEditorFocused = true
        installKeyEventMonitor()
    }

    func editorDidBlur() {
        guard isEditorFocused else { return }
        isEditorFocused = false
        dismissSuggestion()
        removeKeyEventMonitor()
    }

    func uninstall() {
        guard !isUninstalled else { return }
        isUninstalled = true
        isEditorFocused = false

        debounceTask?.cancel()
        debounceTask = nil
        requestTask?.cancel()
        requestTask = nil

        renderer.uninstall()
        removeKeyEventMonitor()

        sourceResolver = nil
        controller = nil
    }

    // MARK: - Text Change Handling

    func handleTextChange() {
        dismissSuggestion()
        scheduleSuggestion()
    }

    func handleSelectionChange() {
        guard currentSuggestion != nil else { return }
        guard let controller else { return }

        let cursorOffset = controller.cursorPositions.first?.range.location ?? NSNotFound
        if cursorOffset != suggestionOffset {
            dismissSuggestion()
        }
    }

    // MARK: - Suggestion Scheduling

    private func scheduleSuggestion() {
        debounceTask?.cancel()
        guard isEnabled() else { return }

        let delay = Duration.milliseconds(AppSettingsManager.shared.ai.clampedInlineSuggestionDebounceMs)
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.requestSuggestion()
        }
    }

    private func isEnabled() -> Bool {
        guard let source = sourceResolver?() else { return false }
        guard source.isAvailable else { return false }
        guard let controller else { return false }
        guard let textView = controller.textView else { return false }
        guard textView.window?.firstResponder === textView else { return false }
        guard let cursor = controller.cursorPositions.first,
              cursor.range.length == 0 else { return false }

        let text = textView.string
        guard (text as NSString).length > 0 else { return false }

        return true
    }

    // MARK: - Request

    private func requestSuggestion() {
        guard isEnabled() else { return }
        guard let source = sourceResolver?() else { return }
        guard let controller, let textView = controller.textView else { return }

        let cursorOffset = controller.cursorPositions.first?.range.location ?? 0
        guard cursorOffset > 0 else { return }

        let fullText = textView.string
        let nsText = fullText as NSString
        let textBefore = nsText.substring(to: min(cursorOffset, nsText.length))

        let (line, character) = Self.computeLineCharacter(text: nsText, offset: cursorOffset)

        let context = SuggestionContext(
            textBefore: textBefore,
            fullText: fullText,
            cursorOffset: cursorOffset,
            cursorLine: line,
            cursorCharacter: character
        )

        let requestedFromIdentity = source.sourceIdentity

        requestTask?.cancel()
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.suggestionOffset = cursorOffset

            do {
                guard let suggestion = try await source.requestSuggestion(context: context) else { return }
                guard !Task.isCancelled else { return }
                guard let activeIdentity = self.sourceResolver?()?.sourceIdentity,
                      activeIdentity == requestedFromIdentity else { return }
                guard !suggestion.text.isEmpty else { return }

                self.currentSuggestion = suggestion
                self.renderer.show(suggestion.text, at: cursorOffset)
                source.didShowSuggestion(suggestion)
            } catch {
                if !Task.isCancelled {
                    Self.logger.debug("Inline suggestion failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Accept / Dismiss

    private func acceptSuggestion() {
        guard let suggestion = currentSuggestion,
              let textView = controller?.textView else { return }

        renderer.hide()
        currentSuggestion = nil

        if let range = suggestion.replacementRange {
            textView.replaceCharacters(in: range, with: suggestion.replacementText)
        } else {
            textView.replaceCharacters(
                in: NSRange(location: suggestionOffset, length: 0),
                with: suggestion.replacementText
            )
        }

        sourceResolver?()?.didAcceptSuggestion(suggestion)
    }

    func dismissSuggestion() {
        debounceTask?.cancel()
        debounceTask = nil
        requestTask?.cancel()
        requestTask = nil

        if let suggestion = currentSuggestion {
            sourceResolver?()?.didDismissSuggestion(suggestion)
        }

        renderer.hide()
        currentSuggestion = nil
    }

    // MARK: - Key Event Monitor

    private func installKeyEventMonitor() {
        removeKeyEventMonitor()
        _keyEventMonitor.withLock { $0 = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] nsEvent in
            nonisolated(unsafe) let event = nsEvent
            return MainActor.assumeIsolated {
                guard let self, self.isEditorFocused else { return event }

                guard self.currentSuggestion != nil else { return event }

                guard let textView = self.controller?.textView,
                      event.window === textView.window,
                      textView.window?.firstResponder === textView else { return event }

                switch event.keyCode {
                case 48:
                    self.acceptSuggestion()
                    return nil

                case 53:
                    self.dismissSuggestion()
                    return event

                default:
                    self.dismissSuggestion()
                    return event
                }
            }
        }
        }
    }

    private func removeKeyEventMonitor() {
        _keyEventMonitor.withLock {
            if let monitor = $0 { NSEvent.removeMonitor(monitor) }
            $0 = nil
        }
    }

    // MARK: - Helpers

    static func computeLineCharacter(text: NSString, offset: Int) -> (Int, Int) {
        var line = 0
        var lineStart = 0
        let length = text.length
        let target = min(offset, length)

        var i = 0
        while i < target {
            let ch = text.character(at: i)
            i += 1
            if ch == 0x0A {
                line += 1
                lineStart = i
            }
        }

        return (line, target - lineStart)
    }
}
