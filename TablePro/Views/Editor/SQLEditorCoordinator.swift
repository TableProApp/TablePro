//
//  SQLEditorCoordinator.swift
//  TablePro
//
//  Central coordinator for the TPEditorView-based SQL editor.
//  Manages Vim mode, AI inline suggestions, AI context menu,
//  and editor focus state.
//

import AppKit
import Observation
import os

@Observable
@MainActor
final class SQLEditorCoordinator: TPEditorDelegate {
    // MARK: - Properties

    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLEditorCoordinator")

    /// Vim mode for UI observation
    private(set) var vimMode: VimMode = .normal

    /// Shared schema provider for inline AI suggestions
    @ObservationIgnored var schemaProvider: SQLSchemaProvider?
    @ObservationIgnored var onCloseTab: (() -> Void)?
    @ObservationIgnored var onExecuteQuery: (() -> Void)?
    @ObservationIgnored var onAIExplain: ((String) -> Void)?
    @ObservationIgnored var onAIOptimize: ((String) -> Void)?
    @ObservationIgnored var onSaveAsFavorite: ((String) -> Void)?

    @ObservationIgnored private var vimEngine: VimEngine?
    @ObservationIgnored private var vimKeyInterceptor: VimKeyInterceptor?
    @ObservationIgnored private var commandHandler = VimCommandLineHandler()
    @ObservationIgnored private var vimCursorManager: VimCursorManager?
    @ObservationIgnored private var inlineSuggestionManager: InlineSuggestionManager?
    @ObservationIgnored private var contextMenu: AIEditorContextMenu?
    @ObservationIgnored private var editorSettingsObserver: NSObjectProtocol?
    @ObservationIgnored private weak var textView: TPTextView?
    @ObservationIgnored private var didDestroy = false

    deinit {
        if let observer = editorSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Install / Destroy

    /// Install all integrations on a text view
    func install(on textView: TPTextView) {
        self.textView = textView
        textView.editorDelegate = self

        EditorEventRouter.shared.register(textView: textView)
        installAIContextMenu(textView: textView)
        installInlineSuggestionManager(textView: textView)
        installVimModeIfEnabled(textView: textView)
        installSettingsObserver()
    }

    func destroy() {
        guard !didDestroy else { return }
        didDestroy = true

        uninstallVimKeyInterceptor()

        inlineSuggestionManager?.uninstall()
        inlineSuggestionManager = nil

        onCloseTab = nil
        onExecuteQuery = nil
        onAIExplain = nil
        onAIOptimize = nil
        onSaveAsFavorite = nil
        schemaProvider = nil
        contextMenu = nil
        vimEngine = nil
        vimCursorManager = nil

        if let textView {
            EditorEventRouter.shared.unregister(textView: textView)
        }

        if let observer = editorSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
            editorSettingsObserver = nil
        }

        Self.logger.debug("SQLEditorCoordinator destroyed")
    }

    // MARK: - TPEditorDelegate

    func editorDidChangeText(_ editor: TPTextView) {
        vimEngine?.invalidateLineCache()
        inlineSuggestionManager?.handleTextChange()
        vimCursorManager?.updatePosition()
    }

    func editorDidChangeSelection(_ editor: TPTextView, range: NSRange) {
        inlineSuggestionManager?.handleSelectionChange()
        vimCursorManager?.updatePosition()
    }

    func editorDidReceiveKeyDown(_ editor: TPTextView, event: NSEvent) -> Bool {
        // Vim interceptor handles key events via its own NSEvent monitor
        false
    }

    func editorDidBecomeFirstResponder(_ editor: TPTextView) {
        vimKeyInterceptor?.editorDidFocus()
        inlineSuggestionManager?.editorDidFocus()
        vimCursorManager?.resumeBlink()
    }

    func editorDidResignFirstResponder(_ editor: TPTextView) {
        vimKeyInterceptor?.editorDidBlur()
        inlineSuggestionManager?.editorDidBlur()
        vimCursorManager?.pauseBlink()
    }

    // MARK: - AI Context Menu

    private func installAIContextMenu(textView: TPTextView) {
        let menu = AIEditorContextMenu(title: "")
        menu.hasSelection = { [weak textView] in
            guard let textView else { return false }
            return textView.selectedRange().length > 0
        }
        menu.selectedText = { [weak textView] in
            guard let textView else { return nil }
            let range = textView.selectedRange()
            guard range.length > 0 else { return nil }
            return (textView.string as NSString).substring(with: range)
        }
        menu.fullText = { [weak textView] in
            textView?.string
        }
        menu.onExplainWithAI = { [weak self] text in self?.onAIExplain?(text) }
        menu.onOptimizeWithAI = { [weak self] text in self?.onAIOptimize?(text) }
        menu.onSaveAsFavorite = { [weak self] text in self?.onSaveAsFavorite?(text) }
        contextMenu = menu
        textView.menu = menu
    }

    // MARK: - Inline Suggestion Manager

    private func installInlineSuggestionManager(textView: TPTextView) {
        let manager = InlineSuggestionManager()
        manager.install(textView: textView, schemaProvider: schemaProvider)
        inlineSuggestionManager = manager
    }

    // MARK: - Vim Mode

    private func installVimModeIfEnabled(textView: TPTextView) {
        guard AppSettingsManager.shared.editor.vimModeEnabled else { return }
        installVimKeyInterceptor(textView: textView)
    }

    private func installVimKeyInterceptor(textView: TPTextView) {
        let adapter = VimTextBufferAdapter(textView: textView)
        let engine = VimEngine(buffer: adapter)

        engine.onModeChange = { [weak self] mode in
            self?.vimMode = mode
            self?.vimCursorManager?.updateMode(mode)
        }

        commandHandler.onExecuteQuery = { [weak self] in
            self?.onExecuteQuery?()
        }
        commandHandler.onCloseTab = { [weak self] in
            self?.onCloseTab?()
        }
        engine.onCommand = { [weak self] command in
            self?.commandHandler.handle(command)
        }

        let interceptor = VimKeyInterceptor(engine: engine, inlineSuggestionManager: inlineSuggestionManager)
        interceptor.install(textView: textView)

        self.vimEngine = engine
        self.vimKeyInterceptor = interceptor
        self.vimMode = .normal

        let cursorManager = VimCursorManager()
        cursorManager.install(textView: textView)
        self.vimCursorManager = cursorManager
    }

    private func uninstallVimKeyInterceptor() {
        vimKeyInterceptor?.uninstall()
        vimCursorManager?.uninstall()
        vimCursorManager = nil
        vimKeyInterceptor = nil
        vimEngine = nil
        vimMode = .normal
    }

    private func handleVimSettingsChange() {
        guard let textView else { return }
        let enabled = AppSettingsManager.shared.editor.vimModeEnabled
        if enabled && vimKeyInterceptor == nil {
            installVimKeyInterceptor(textView: textView)
        } else if !enabled && vimKeyInterceptor != nil {
            uninstallVimKeyInterceptor()
        }
    }

    // MARK: - Settings Observer

    private func installSettingsObserver() {
        editorSettingsObserver = NotificationCenter.default.addObserver(
            forName: .editorSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.handleVimSettingsChange()
                self.vimCursorManager?.updatePosition()
            }
        }
    }
}
