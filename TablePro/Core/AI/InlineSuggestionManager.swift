//
//  InlineSuggestionManager.swift
//  TablePro
//
//  Manages inline AI suggestions (ghost text) in the SQL editor.
//  Debounces typing, streams completions from AI providers, and renders
//  ghost text as a CATextLayer overlay on the text view.
//

@preconcurrency import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import os

/// Manages Copilot-style inline SQL suggestions rendered as ghost text
@MainActor
final class InlineSuggestionManager {
    // MARK: - Properties

    private static let logger = Logger(subsystem: "com.TablePro", category: "InlineSuggestion")

    private weak var controller: TextViewController?
    private var debounceTimer: Timer?
    private var currentTask: Task<Void, Never>?
    private let _keyEventMonitor = OSAllocatedUnfairLock<Any?>(initialState: nil)
    private let _scrollObserver = OSAllocatedUnfairLock<Any?>(initialState: nil)
    private(set) var isEditorFocused = false

    deinit {
        if let monitor = _keyEventMonitor.withLock({ $0 }) { NSEvent.removeMonitor(monitor) }
        if let observer = _scrollObserver.withLock({ $0 }) { NotificationCenter.default.removeObserver(observer) }
    }

    /// The currently displayed suggestion text, nil when no suggestion is active
    private(set) var currentSuggestion: String?

    /// The cursor offset where the suggestion was generated
    private var suggestionOffset: Int = 0

    /// Generation counter to detect stale completions
    private var generationID: UInt = 0

    /// The ghost text layer displaying the suggestion
    private var ghostLayer: CATextLayer?

    /// Debounce interval in seconds before requesting a suggestion
    private let debounceInterval: TimeInterval = 0.5

    /// Shared schema provider (passed from coordinator, avoids duplicate schema fetches)
    private var schemaProvider: SQLSchemaProvider?

    /// Guard against double-uninstall (deinit + destroy can both call uninstall)
    private var isUninstalled = false

    // MARK: - Install / Uninstall

    /// Install the manager on a TextViewController
    func install(controller: TextViewController, schemaProvider: SQLSchemaProvider?) {
        self.controller = controller
        self.schemaProvider = schemaProvider
        installScrollObserver()
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

    /// Remove all observers and layers
    func uninstall() {
        guard !isUninstalled else { return }
        isUninstalled = true
        isEditorFocused = false

        debounceTimer?.invalidate()
        debounceTimer = nil
        currentTask?.cancel()
        currentTask = nil
        removeGhostLayer()

        removeKeyEventMonitor()

        if let observer = _scrollObserver.withLock({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
            _scrollObserver.withLock { $0 = nil }
        }

        schemaProvider = nil
        controller = nil
    }

    // MARK: - Text Change Handling

    /// Called by the coordinator when text changes
    func handleTextChange() {
        dismissSuggestion()
        scheduleSuggestion()
    }

    /// Called by the coordinator when cursor selection changes
    func handleSelectionChange() {
        // If cursor moved away from the suggestion offset, dismiss
        guard currentSuggestion != nil else { return }
        guard let controller else { return }

        let cursorOffset = controller.cursorPositions.first?.range.location ?? NSNotFound
        if cursorOffset != suggestionOffset {
            dismissSuggestion()
        }
    }

    // MARK: - Suggestion Scheduling

    private func scheduleSuggestion() {
        debounceTimer?.invalidate()

        guard isEnabled() else { return }

        let timer = Timer(timeInterval: debounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestSuggestion()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        debounceTimer = timer
    }

    private func isEnabled() -> Bool {
        let settings = AppSettingsManager.shared.ai
        guard settings.inlineSuggestEnabled else { return false }
        guard let controller else { return false }
        guard let textView = controller.textView else { return false }

        // Must be first responder
        guard textView.window?.firstResponder === textView else { return false }

        // Must have a single cursor with no selection
        guard let cursor = controller.cursorPositions.first,
              cursor.range.length == 0 else { return false }

        // Must have some text
        let text = textView.string
        guard (text as NSString).length > 0 else { return false }

        return true
    }

    // MARK: - Schema Context

    private func buildSystemPrompt() async -> String {
        let settings = AppSettingsManager.shared.ai

        guard settings.includeSchema,
              let provider = schemaProvider else {
            return AIPromptTemplates.inlineSuggestSystemPrompt()
        }

        // Build schema context from shared provider's cached data
        let schemaContext = await provider.buildSchemaContextForAI(settings: settings)

        if let schemaContext, !schemaContext.isEmpty {
            return AIPromptTemplates.inlineSuggestSystemPrompt(schemaContext: schemaContext)
        }
        return AIPromptTemplates.inlineSuggestSystemPrompt()
    }

    // MARK: - AI Request

    private func requestSuggestion() {
        guard isEnabled() else { return }
        guard let controller, let textView = controller.textView else { return }

        let cursorOffset = controller.cursorPositions.first?.range.location ?? 0
        guard cursorOffset > 0 else { return }

        let fullText = textView.string
        let nsText = fullText as NSString
        let textBefore = nsText.substring(to: min(cursorOffset, nsText.length))

        // Cancel any in-flight request
        currentTask?.cancel()
        generationID &+= 1
        let myGeneration = generationID

        currentTask = Task { [weak self] in
            guard let self else { return }

            do {
                let suggestion = try await self.fetchSuggestion(textBefore: textBefore, fullQuery: fullText)

                guard !Task.isCancelled, self.generationID == myGeneration else { return }

                let cleaned = self.cleanSuggestion(suggestion)
                guard !cleaned.isEmpty else { return }

                self.currentSuggestion = cleaned
                self.suggestionOffset = cursorOffset
                self.showGhostText(cleaned, at: cursorOffset)
            } catch {
                if !Task.isCancelled {
                    Self.logger.debug("Inline suggestion failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func fetchSuggestion(textBefore: String, fullQuery: String) async throws -> String {
        let settings = AppSettingsManager.shared.ai

        guard let (config, apiKey) = AIProviderFactory.resolveProvider(for: .inlineSuggest, settings: settings) else {
            throw AIProviderError.networkError("No AI provider configured")
        }

        let model = AIProviderFactory.resolveModel(for: .inlineSuggest, config: config, settings: settings)
        let provider = AIProviderFactory.createProvider(for: config, apiKey: apiKey)

        let userMessage = AIPromptTemplates.inlineSuggest(textBefore: textBefore, fullQuery: fullQuery)
        let messages = [
            AIChatMessage(role: .user, content: userMessage)
        ]

        let systemPrompt = await buildSystemPrompt()

        var accumulated = ""
        let stream = provider.streamChat(
            messages: messages,
            model: model,
            systemPrompt: systemPrompt
        )

        for try await event in stream {
            guard !Task.isCancelled else { break }
            switch event {
            case .text(let token):
                accumulated += token
                // Progressive update: show partial ghost text as tokens arrive
                await MainActor.run { [weak self, accumulated] in
                    guard let self else { return }
                    let cleaned = self.cleanSuggestion(accumulated)
                    if !cleaned.isEmpty {
                        self.currentSuggestion = cleaned
                        self.showGhostText(cleaned, at: self.suggestionOffset)
                    }
                }
            case .usage:
                break
            }
        }

        return accumulated
    }

    /// Clean the AI suggestion: strip thinking blocks, leading newlines,
    /// and trailing whitespace, but preserve leading spaces.
    private func cleanSuggestion(_ raw: String) -> String {
        var result = raw

        // Strip thinking blocks (e.g. <think>...</think>, <THINK>...</THINK>)
        // Some models emit chain-of-thought reasoning wrapped in these tags
        result = stripThinkingBlocks(result)

        // Strip leading newlines only (preserve leading spaces)
        while result.first?.isNewline == true {
            result.removeFirst()
        }
        // Strip trailing whitespace and newlines
        while result.last?.isWhitespace == true {
            result.removeLast()
        }
        return result
    }

    /// Precompiled regex for stripping `<think>...</think>` blocks
    private static let thinkingRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<think>.*?</think>|<think>.*$",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// Remove `<think>...</think>` blocks (case-insensitive) from AI output.
    /// Handles partial/unclosed tags too — if a `<think>` opens but never closes,
    /// everything from that tag onward is stripped.
    private func stripThinkingBlocks(_ text: String) -> String {
        guard let regex = Self.thinkingRegex else { return text }

        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: ""
        )
    }

    // MARK: - Ghost Text Rendering

    private func showGhostText(_ text: String, at offset: Int) {
        guard let textView = controller?.textView else { return }
        guard let rect = textView.layoutManager.rectForOffset(offset) else { return }

        removeGhostLayer()

        let layer = CATextLayer()
        layer.contentsScale = textView.window?.backingScaleFactor ?? 2.0
        layer.allowsFontSubpixelQuantization = true

        // Use the editor's font and grey color for ghost appearance
        let font = ThemeEngine.shared.editorFonts.font
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        layer.string = NSAttributedString(string: text, attributes: attrs)

        // Calculate the size needed for the ghost text
        let maxWidth = max(textView.bounds.width - rect.origin.x - 8, 200)
        let boundingRect = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )

        // Position the layer at the cursor location
        // isFlipped = true in CodeEditTextView, so y=0 is top — coords match layoutManager directly
        layer.frame = CGRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: ceil(boundingRect.width) + 4,
            height: ceil(boundingRect.height) + 2
        )
        layer.isWrapped = true

        textView.layer?.addSublayer(layer)
        ghostLayer = layer
    }

    private func removeGhostLayer() {
        ghostLayer?.removeFromSuperlayer()
        ghostLayer = nil
    }

    // MARK: - Accept / Dismiss

    /// Accept the current suggestion by inserting it at the cursor
    private func acceptSuggestion() {
        guard let suggestion = currentSuggestion,
              let textView = controller?.textView else { return }

        let offset = suggestionOffset
        removeGhostLayer()
        currentSuggestion = nil

        textView.replaceCharacters(
            in: NSRange(location: offset, length: 0),
            with: suggestion
        )
    }

    /// Dismiss the current suggestion without inserting
    func dismissSuggestion() {
        debounceTimer?.invalidate()
        currentTask?.cancel()
        currentTask = nil
        removeGhostLayer()
        currentSuggestion = nil
    }

    // MARK: - Key Event Monitor

    private func installKeyEventMonitor() {
        removeKeyEventMonitor()
        _keyEventMonitor.withLock { $0 = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] nsEvent in
            nonisolated(unsafe) let event = nsEvent
            return MainActor.assumeIsolated {
                guard let self, self.isEditorFocused else { return event }

                guard AppSettingsManager.shared.ai.inlineSuggestEnabled else { return event }

                guard self.currentSuggestion != nil else { return event }

                guard let textView = self.controller?.textView,
                      event.window === textView.window,
                      textView.window?.firstResponder === textView else { return event }

                switch event.keyCode {
                case 48: // Tab — accept suggestion
                    Task { @MainActor [weak self] in
                        self?.acceptSuggestion()
                    }
                    return nil

                case 53: // Escape — dismiss suggestion
                    Task { @MainActor [weak self] in
                        self?.dismissSuggestion()
                    }
                    return nil

                default:
                    Task { @MainActor [weak self] in
                        self?.dismissSuggestion()
                    }
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

    // MARK: - Scroll Observer

    private func installScrollObserver() {
        guard let scrollView = controller?.scrollView else { return }
        let contentView = scrollView.contentView

        _scrollObserver.withLock {
            $0 = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let suggestion = self.currentSuggestion {
                        // Reposition the ghost layer after scroll
                        self.showGhostText(suggestion, at: self.suggestionOffset)
                    }
                }
            }
        }
    }
}
