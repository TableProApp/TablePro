//
//  SuggestionViewModel.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 7/22/25.
//

import AppKit
import os

@MainActor
final class SuggestionViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.TableProEditorKit", category: "SuggestionVM")
    /// The items to be displayed in the window
    @Published var items: [CodeSuggestionEntry] = []
    @Published var selectedIndex: Int = 0
    @Published var themeBackground: NSColor = .windowBackgroundColor
    @Published var themeTextColor: NSColor = .labelColor

    var itemsRequestTask: Task<Void, Never>?
    weak var activeTextView: TextViewController?
    private(set) var isApplyingCompletion = false

    /// Whether a suggestion window is on screen for ``activeTextView``.
    ///
    /// `activeTextView` answers a different question: who a request is *for*. It is assigned
    /// before the delegate is awaited, so it stays set for the whole of a request that may end
    /// without presenting anything. Reading it as "a window is open" is what let
    /// ``cursorsUpdated(textView:delegate:position:close:)`` file new items into a panel nobody
    /// could see and never ask for a session again.
    var isPresented = false

    /// Fenced so a superseded request cannot write into the session that replaced it. A cancelled
    /// `Task` resumes after its successor's handle is already stored, and an unguarded cleanup
    /// there clears the live request instead of its own.
    private var requestGeneration = 0

    weak var delegate: CodeSuggestionDelegate?

    /// Invoked after a successful apply so the owning controller can dismiss the
    /// suggestion window through its own ``close()`` override (which performs the
    /// monitor and state cleanup). Bypassing this and calling `NSWindow.close()`
    /// directly leaves the local key monitor installed.
    var onApply: (() -> Void)?

    /// Invoked when a click lands on a non-interactive part of the panel (background,
    /// padding, rounded corners, divider, preview, or the "No Completions" label).
    /// The owning controller dismisses the window so the click is not swallowed.
    var onBackgroundTap: (() -> Void)?

    private var cursorPosition: CursorPosition?
    private var syntaxHighlightedCache: [Int: NSAttributedString] = [:]

    var selectedItem: CodeSuggestionEntry? {
        guard selectedIndex >= 0, selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }

    func moveUp() {
        guard selectedIndex > 0 else { return }
        selectedIndex -= 1
        notifySelection()
    }

    func moveDown() {
        guard selectedIndex < items.count - 1 else { return }
        selectedIndex += 1
        notifySelection()
    }

    private func notifySelection() {
        if let item = selectedItem {
            delegate?.completionWindowDidSelect(item: item)
        }
    }

    func updateTheme(from textView: TextViewController) {
        themeTextColor = textView.theme.text.color
        switch textView.systemAppearance {
        case .aqua:
            let color = textView.theme.background
            if color != .clear {
                themeBackground = NSColor(
                    red: color.redComponent * 0.95,
                    green: color.greenComponent * 0.95,
                    blue: color.blueComponent * 0.95,
                    alpha: 1.0
                )
            } else {
                themeBackground = .windowBackgroundColor
            }
        case .darkAqua:
            themeBackground = textView.theme.background
        default:
            break
        }
    }

    func showCompletions(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        cursorPosition: CursorPosition,
        isManualTrigger: Bool = false,
        showWindowOnParent: @escaping @MainActor (NSWindow, NSRect) -> Void
    ) {
        guard !isApplyingCompletion else { return }

        self.activeTextView = nil
        self.delegate = nil
        self.isPresented = false
        itemsRequestTask?.cancel()

        guard textView.view.window != nil else {
            Self.logger.warning("showCompletions: textView.view.window is nil")
            return
        }

        self.activeTextView = textView
        self.delegate = delegate
        requestGeneration &+= 1
        let generation = requestGeneration
        itemsRequestTask = Task {
            defer {
                if self.requestGeneration == generation {
                    self.itemsRequestTask = nil
                }
            }

            do {
                guard let completionItems = await delegate.completionSuggestionsRequested(
                    textView: textView,
                    cursorPosition: cursorPosition,
                    isManualTrigger: isManualTrigger
                ) else {
                    Self.logger.debug("showCompletions: delegate returned nil items")
                    self.endSession(generation: generation)
                    return
                }

                Self.logger.debug("showCompletions: got \(completionItems.items.count) items")

                try Task.checkCancellation()
                try await MainActor.run {
                    try Task.checkCancellation()

                    guard let window = textView.view.window,
                          window.isKeyWindow,
                          let responder = window.firstResponder as? NSView,
                          responder.isDescendant(of: textView.view) else {
                        Self.logger.debug("showCompletions: editor lost focus while completions were loading")
                        self.endSession(generation: generation)
                        return
                    }

                    guard let windowPosition = textView.resolveCursorPosition(completionItems.windowPosition),
                          let cursorRect = textView.textView.layoutManager.rectForOffset(
                            windowPosition.range.location
                          ) else {
                        Self.logger.warning("showCompletions: cursor rect resolution failed")
                        self.endSession(generation: generation)
                        return
                    }

                    guard let items = self.itemsForLiveCursor(
                        requested: completionItems.items,
                        answeredAt: windowPosition,
                        textView: textView,
                        delegate: delegate
                    ) else {
                        Self.logger.debug("showCompletions: nothing matches where the cursor moved while loading")
                        self.endSession(generation: generation)
                        return
                    }

                    let screenCursorRect = window.convertToScreen(
                        textView.textView.convert(cursorRect, to: nil)
                    )

                    self.items = items
                    self.selectedIndex = 0
                    self.syntaxHighlightedCache = [:]
                    self.notifySelection()

                    guard self.requestGeneration == generation, self.activeTextView === textView else {
                        return
                    }

                    showWindowOnParent(window, screenCursorRect)
                    self.isPresented = true
                }
            } catch {
                self.endSession(generation: generation)
                return
            }
        }
    }

    private func itemsForLiveCursor(
        requested: [CodeSuggestionEntry],
        answeredAt windowPosition: CursorPosition,
        textView: TextViewController,
        delegate: CodeSuggestionDelegate
    ) -> [CodeSuggestionEntry]? {
        guard let liveCursor = textView.cursorPositions.first,
              liveCursor.range != windowPosition.range else {
            return requested
        }
        guard let reranked = delegate.completionOnCursorMove(textView: textView, cursorPosition: liveCursor),
              !reranked.isEmpty else {
            return nil
        }
        return reranked
    }

    /// Ends the session this request owns, so nothing is left claiming a window that was never
    /// shown. Superseded requests end nothing: their successor already owns the session.
    private func endSession(generation: Int) {
        guard requestGeneration == generation else { return }
        endSession()
    }

    /// The single terminal transition, idempotent so it can run from a request that presented
    /// nothing and again from the window's own close.
    private func endSession() {
        isPresented = false
        items.removeAll()
        selectedIndex = 0
        syntaxHighlightedCache = [:]
        activeTextView = nil
        if let delegate {
            self.delegate = nil
            delegate.completionWindowDidClose()
        }
    }

    func cursorsUpdated(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        position: CursorPosition,
        close: () -> Void
    ) {
        guard !isApplyingCompletion else { return }

        if activeTextView !== textView {
            itemsRequestTask?.cancel()
            itemsRequestTask = nil
            close()
            return
        }

        if isPresented, let newItems = delegate.completionOnCursorMove(
            textView: textView,
            cursorPosition: position
        ), !newItems.isEmpty {
            items = newItems
            selectedIndex = 0
            syntaxHighlightedCache = [:]
            notifySelection()
            return
        }

        guard itemsRequestTask == nil else { return }

        close()
    }

    func didSelect(item: CodeSuggestionEntry) {
        delegate?.completionWindowDidSelect(item: item)
    }

    func applySelectedItem(item: CodeSuggestionEntry) {
        guard let activeTextView else {
            return
        }
        isApplyingCompletion = true
        self.delegate?.completionWindowApplyCompletion(
            item: item,
            textView: activeTextView,
            cursorPosition: activeTextView.cursorPositions.first
        )
        isApplyingCompletion = false
        onApply?()
    }

    func willClose() {
        itemsRequestTask?.cancel()
        itemsRequestTask = nil
        endSession()
    }

    func syntaxHighlights(forIndex index: Int) -> NSAttributedString? {
        if let cached = syntaxHighlightedCache[index] {
            return cached
        }

        if let sourcePreview = items[index].sourcePreview,
           let theme = activeTextView?.theme,
           let font = activeTextView?.font,
           let language = activeTextView?.language {
            let string = TreeSitterClient.quickHighlight(
                string: sourcePreview,
                theme: theme,
                font: font,
                language: language
            )
            syntaxHighlightedCache[index] = string
            return string
        }

        return nil
    }
}
