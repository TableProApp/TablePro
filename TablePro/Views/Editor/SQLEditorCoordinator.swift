//
//  SQLEditorCoordinator.swift
//  TablePro
//
//  TextViewCoordinator for the CodeEditSourceEditor-based SQL editor.
//  Handles find panel workarounds and horizontal scrolling fix.
//

import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import Observation
import os

/// Coordinator for the SQL editor — manages find panel, horizontal scrolling, and scroll-to-match
@Observable
@MainActor
final class SQLEditorCoordinator: TextViewCoordinator {
    // MARK: - Properties

    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLEditorCoordinator")

    @ObservationIgnored weak var controller: TextViewController?
    /// Shared schema provider for inline AI suggestions (avoids duplicate schema fetches)
    @ObservationIgnored var schemaProvider: SQLSchemaProvider?
    @ObservationIgnored private var contextMenu: AIEditorContextMenu?
    @ObservationIgnored private var inlineSuggestionManager: InlineSuggestionManager?
    @ObservationIgnored private var editorSettingsObserver: NSObjectProtocol?
    @ObservationIgnored private var windowKeyObserver: NSObjectProtocol?
    /// Debounce work item for frame-change notification to avoid
    /// triggering syntax highlight viewport recalculation on every keystroke.
    @ObservationIgnored private var frameChangeWorkItem: DispatchWorkItem?
    @ObservationIgnored private var wasEditorFocused = false
    @ObservationIgnored private var didDestroy = false

    /// Test-only accessor for destroy state
    var isDestroyed: Bool { didDestroy }

    /// Vim mode for UI observation
    private(set) var vimMode: VimMode = .normal
    @ObservationIgnored private var vimEngine: VimEngine?
    @ObservationIgnored private var vimKeyInterceptor: VimKeyInterceptor?
    @ObservationIgnored private var commandHandler = VimCommandLineHandler()
    @ObservationIgnored private var vimCursorManager: VimCursorManager?
    @ObservationIgnored var onCloseTab: (() -> Void)?
    @ObservationIgnored var onExecuteQuery: (() -> Void)?
    @ObservationIgnored var onAIExplain: ((String) -> Void)?
    @ObservationIgnored var onAIOptimize: ((String) -> Void)?
    @ObservationIgnored var onSaveAsFavorite: ((String) -> Void)?

    /// Whether the editor text view is currently the first responder.
    /// Used to guard cursor propagation — when the find panel highlights
    /// a match it changes the selection programmatically, and propagating
    /// that to SwiftUI triggers a re-render that disrupts the find panel's
    /// @FocusState.
    var isEditorFirstResponder: Bool {
        guard let textView = controller?.textView else { return false }
        return textView.window?.firstResponder === textView
    }

    deinit {
        if let observer = editorSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = windowKeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        frameChangeWorkItem?.cancel()
    }

    private func cleanupMonitors() {
        if let observer = editorSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
            editorSettingsObserver = nil
        }
        if let observer = windowKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            windowKeyObserver = nil
        }
        frameChangeWorkItem?.cancel()
        frameChangeWorkItem = nil
    }

    // MARK: - TextViewCoordinator

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller

        // Deferred to next run loop because prepareCoordinator runs during
        // TextViewController.init, before the view hierarchy is fully loaded.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fixFindPanelHitTesting(controller: controller)
            self.applyHorizontalScrollFix(controller: controller)
            self.installAIContextMenu(controller: controller)
            self.installInlineSuggestionManager(controller: controller)
            self.installVimModeIfEnabled(controller: controller)
            if let textView = controller.textView {
                EditorEventRouter.shared.register(self, textView: textView)

                // Auto-focus: make the editor first responder, then ensure a
                // cursor exists. Order matters — setCursorPositions calls
                // updateSelectionViews which guards on isFirstResponder.
                if let window = textView.window {
                    window.makeFirstResponder(textView)
                }
                if controller.cursorPositions.isEmpty {
                    controller.setCursorPositions([CursorPosition(range: NSRange(location: 0, length: 0))])
                }

                // Recreate cursor views when the window regains key status.
                // resignKeyWindow() on the text view calls removeCursors() which
                // destroys cursor subviews, but becomeKeyWindow() only resets the
                // blink timer without recreating them.
                self.installWindowKeyObserver(for: textView.window)
            }
        }
    }

    func textViewDidChangeText(controller: TextViewController) {
        // Invalidate Vim buffer's cached line count after text changes
        vimEngine?.invalidateLineCache()

        // Notify inline suggestion manager immediately (lightweight)
        DispatchQueue.main.async { [weak self] in
            self?.inlineSuggestionManager?.handleTextChange()
            self?.vimCursorManager?.updatePosition()
        }

        // Throttle frame-change notification — during rapid typing, only the
        // last notification matters. The highlighter recalculates the visible
        // range on each notification, so coalescing saves redundant layout work.
        frameChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak controller] in
            guard let self, let controller, let textView = controller.textView else { return }
            NotificationCenter.default.post(
                name: NSView.frameDidChangeNotification,
                object: textView
            )
            // Re-check horizontal scroll fix after text change.
            // Layout has processed the new text by now, so estimatedWidth is current.
            self.ensureHorizontalScrollFix(controller: controller)
        }
        frameChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        inlineSuggestionManager?.handleSelectionChange()
        vimCursorManager?.updatePosition()

        // When the find panel navigates to a match, it changes the selection
        // but the editor is not first responder. Scroll to the match manually
        // because CodeEditTextView's scrollSelectionToVisible() fails for
        // off-screen matches (TextSelection.boundingRect is .zero until drawn).
        guard !isEditorFirstResponder else { return }
        guard let range = newPositions.first?.range, range.location != NSNotFound else { return }

        // Defer to next run loop to let EmphasisManager finish its work first.
        DispatchQueue.main.async { [weak controller] in
            controller?.textView.scrollToRange(range)
        }
    }

    func destroy() {
        didDestroy = true

        uninstallVimKeyInterceptor()

        inlineSuggestionManager?.uninstall()
        inlineSuggestionManager = nil

        // Release closure captures to break potential retain cycles
        onCloseTab = nil
        onExecuteQuery = nil
        onAIExplain = nil
        onAIOptimize = nil
        onSaveAsFavorite = nil
        schemaProvider = nil
        contextMenu = nil
        vimEngine = nil
        vimCursorManager = nil

        // Release editor controller heavy state
        controller?.releaseHeavyState()

        EditorEventRouter.shared.unregister(self)
        Self.logger.debug("SQLEditorCoordinator destroyed")
        cleanupMonitors()
    }

    // MARK: - AI Context Menu

    private func installAIContextMenu(controller: TextViewController) {
        guard controller.textView != nil else { return }
        let menu = AIEditorContextMenu(title: "")
        menu.hasSelection = { [weak controller] in
            guard let controller else { return false }
            return controller.cursorPositions.contains { $0.range.length > 0 }
        }
        menu.selectedText = { [weak controller] in
            guard let controller, let textView = controller.textView else { return nil }
            let range = textView.selectedRange()
            guard range.length > 0 else { return nil }
            return (textView.string as NSString).substring(with: range)
        }
        menu.fullText = { [weak controller] in
            controller?.textView?.string
        }
        menu.onExplainWithAI = { [weak self] text in self?.onAIExplain?(text) }
        menu.onOptimizeWithAI = { [weak self] text in self?.onAIOptimize?(text) }
        menu.onSaveAsFavorite = { [weak self] text in self?.onSaveAsFavorite?(text) }
        contextMenu = menu
    }

    /// Called by EditorEventRouter when a right-click is detected in this editor's text view.
    func showContextMenu(for event: NSEvent, in textView: TextView) {
        guard let menu = contextMenu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: textView)
    }

    // MARK: - Inline Suggestion Manager

    private func installInlineSuggestionManager(controller: TextViewController) {
        let manager = InlineSuggestionManager()
        manager.install(controller: controller, schemaProvider: schemaProvider)
        inlineSuggestionManager = manager
    }

    // MARK: - Vim Mode

    private func installVimModeIfEnabled(controller: TextViewController) {
        guard AppSettingsManager.shared.editor.vimModeEnabled else { return }
        installVimKeyInterceptor(controller: controller)
    }

    private func installVimKeyInterceptor(controller: TextViewController) {
        guard let textView = controller.textView else { return }

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
        interceptor.install(controller: controller)

        self.vimEngine = engine
        self.vimKeyInterceptor = interceptor
        self.vimMode = .normal

        // Install block cursor for Normal mode
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

    private func handleVimSettingsChange(controller: TextViewController) {
        let enabled = AppSettingsManager.shared.editor.vimModeEnabled
        if enabled && vimKeyInterceptor == nil {
            installVimKeyInterceptor(controller: controller)
        } else if !enabled && vimKeyInterceptor != nil {
            uninstallVimKeyInterceptor()
        }
    }

    // MARK: - First Responder Tracking

    func checkFirstResponderChange() {
        let focused = isEditorFirstResponder
        guard focused != wasEditorFocused else { return }
        wasEditorFocused = focused

        if focused {
            vimKeyInterceptor?.editorDidFocus()
            inlineSuggestionManager?.editorDidFocus()
            vimCursorManager?.resumeBlink()
        } else {
            vimKeyInterceptor?.editorDidBlur()
            inlineSuggestionManager?.editorDidBlur()
            vimCursorManager?.pauseBlink()
        }
    }

    // MARK: - Window Key Observer

    /// Observe when the editor's window regains key status (e.g. tab switch) and
    /// recreate cursor views that were destroyed by resignKeyWindow → removeCursors.
    private func installWindowKeyObserver(for window: NSWindow?) {
        guard let window else { return }
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak controller] _ in
            guard let controller, !controller.cursorPositions.isEmpty else { return }
            // At this point becomeKeyWindow → becomeFirstResponder has already run,
            // so isFirstResponder is true and setCursorPositions will create cursor views.
            controller.setCursorPositions(controller.cursorPositions)
        }
    }

    // MARK: - Horizontal Scrolling Fix

    /// Enable horizontal scrolling when word wrap is off.
    ///
    /// **Root cause:** CodeEditSourceEditor sets
    /// `textView.translatesAutoresizingMaskIntoConstraints = false` in `styleTextView()`
    /// but adds no explicit width constraint. Per Apple docs, when Auto Layout constraints
    /// don't fully define the NSScrollView document view's size, the scroll view infers
    /// the document view's width equals the visible area — preventing horizontal scrolling.
    ///
    /// **Fix:** Switch the text view back to autoresize-mask mode and remove `.width` from
    /// the mask so `updateFrameIfNeeded()` can freely expand the frame for long lines.
    /// Only `.height` is kept so the text view tracks the clip view's height changes.
    ///
    /// **Persistence:** `reloadUI()` (called on settings change) re-calls `styleTextView()`
    /// which resets `translatesAutoresizingMaskIntoConstraints = false`. We re-apply the
    /// fix via multiple safety nets:
    /// 1. `.editorSettingsDidChange` observer — catches settings-triggered `reloadUI()`
    /// 2. `textViewDidChangeText` — re-checks after every text change
    /// 3. Delayed initial check — catches the first layout pass after view setup
    private func applyHorizontalScrollFix(controller: TextViewController) {
        setHorizontalScrollProperties(controller: controller)

        // Re-apply after reloadUI() resets translatesAutoresizingMaskIntoConstraints.
        // reloadUI() is called when editor settings change (font, theme, etc.).
        editorSettingsObserver = NotificationCenter.default.addObserver(
            forName: .editorSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            // Defer so it runs AFTER reloadUI() → styleTextView()
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.setHorizontalScrollProperties(controller: controller)
                self.handleVimSettingsChange(controller: controller)
                self.vimCursorManager?.updatePosition()
            }
        }

        // The initial fix runs before text layout — estimatedWidth ≈ 0 at that point.
        // After layout completes (asynchronously), maxLineWidth is updated and the
        // layout delegate calls updateFrameIfNeeded(). However, if a timing race caused
        // updateFrameIfNeeded() to run while translatesAutoresizing was still false,
        // the frame wouldn't expand, and maxLineWidth won't change again (didSet won't
        // re-fire). This delayed check ensures the frame is expanded after initial layout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.ensureHorizontalScrollFix(controller: controller)
        }
    }

    private func setHorizontalScrollProperties(controller: TextViewController) {
        guard !controller.wrapLines else { return }
        guard let textView = controller.textView,
              let scrollView = controller.scrollView else { return }

        // Switch from Auto Layout to autoresize-mask mode
        textView.translatesAutoresizingMaskIntoConstraints = true
        // Only track height (vertical resize). Do NOT include .width — that would
        // lock the text view to the clip view's width, preventing horizontal scroll.
        textView.autoresizingMask = [.height]
        scrollView.hasHorizontalScroller = true
        textView.updateFrameIfNeeded()
    }

    /// Verify horizontal scroll fix is still active and the frame width is correct.
    /// Re-applies the fix if `translatesAutoresizingMaskIntoConstraints` was reset,
    /// and force-expands the frame if it doesn't match the estimated content width.
    private func ensureHorizontalScrollFix(controller: TextViewController) {
        guard !controller.wrapLines else { return }
        guard let textView = controller.textView,
              let scrollView = controller.scrollView else { return }

        // Re-apply if something reset translatesAutoresizingMaskIntoConstraints
        if !textView.translatesAutoresizingMaskIntoConstraints {
            setHorizontalScrollProperties(controller: controller)
            return
        }

        // Fix is in place — verify the frame width matches the content width.
        // updateFrameIfNeeded() may have been called before our fix was applied
        // (during initial layout), so the frame might still be clipped to the
        // visible area. Force-expand it based on the current estimated width.
        let estimatedW = textView.layoutManager.estimatedWidth()
        let clipW = scrollView.contentView.bounds.width
        let targetW = max(estimatedW, clipW)
        if abs(textView.frame.width - targetW) > 0.5 {
            textView.setFrameSize(NSSize(width: targetW, height: textView.frame.height))
        }
    }

    // MARK: - CodeEditSourceEditor Workarounds

    /// Reorder FindViewController's subviews so the find panel is on top for hit testing.
    ///
    /// **Why this is needed:**
    /// CodeEditSourceEditor's FindViewController adds its find panel (an NSHostingView)
    /// before the child scroll view. AppKit hit-tests subviews in reverse order (last
    /// subview first), so the scroll view intercepts clicks meant for the find panel's
    /// buttons. The `zPosition` property only affects rendering order, not hit testing.
    ///
    /// **Why it's deferred:**
    /// `prepareCoordinator` runs during `TextViewController.init`, before the view
    /// hierarchy is fully assembled. We dispatch to the next run loop so the find
    /// panel subviews exist when we reorder them.
    ///
    /// Uses `sortSubviews` to reorder without destroying Auto Layout constraints.
    ///
    /// TODO: Remove when CodeEditSourceEditor fixes subview ordering upstream.
    private func fixFindPanelHitTesting(controller: TextViewController) {
        // controller.view → findViewController.view → [findPanel, scrollView]
        guard let findVCView = controller.view.subviews.first else { return }
        findVCView.sortSubviews({ first, _, _ in
            let firstName = String(describing: type(of: first))
            let isFirstHosting = firstName.contains("HostingView")
            // Place HostingView (find panel) last so it's on top for hit testing
            return isFirstHosting ? .orderedDescending : .orderedAscending
        }, context: nil)
    }
}
