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
    @Published var items: [CodeSuggestionEntry] = [] {
        didSet {
            rowIDs = SuggestionRowID.ids(for: items)
            // Keyed by row, so it is stale the moment the rows change, before the panel measures a preview.
            syntaxHighlightedCache = [:]
            onContentChange?()
        }
    }
    // A row the user picked, by arrow key or click, rather than the first row a new list starts on.
    @Published var selectedIndex: Int = 0 {
        didSet {
            selectionIsChosen = !isResettingSelection
            if selectedIndex != oldValue { onContentChange?() }
        }
    }
    // A re-rank moves rows rather than rewriting each position, so a row that stays keeps its view.
    private(set) var rowIDs: [SuggestionRowID] = []

    var rows: [SuggestionRow] {
        zip(rowIDs, items).enumerated().map { index, pair in
            SuggestionRow(id: pair.0, index: index, item: pair.1)
        }
    }

    // Called in the same turn as the change, so the panel is sized before anything orders it front.
    var onContentChange: (() -> Void)?
    private var selectionIsChosen = false
    private var isResettingSelection = false

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

    private var lastDroppedMovePresents = false

    private var refreshGeneration: Int?
    private var isRefreshingItems: Bool { itemsRequestTask != nil && refreshGeneration == requestGeneration }

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

    // Invoked when a refresh of an open window answers nothing, so the controller closes through its own close().
    var onRequestClose: (() -> Void)?

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
        self.lastDroppedMovePresents = false
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
                guard let response = await delegate.completionSuggestionsRequested(
                    textView: textView,
                    cursorPosition: cursorPosition,
                    isManualTrigger: isManualTrigger
                ) else {
                    Self.logger.debug("showCompletions: delegate returned nil items")
                    self.endSessionOrAskAgain(
                        textView: textView,
                        delegate: delegate,
                        generation: generation,
                        showWindowOnParent: showWindowOnParent
                    )
                    return
                }

                Self.logger.debug("showCompletions: got \(response.items.count) items")

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

                    guard let windowPosition = textView.resolveCursorPosition(response.windowPosition),
                          let cursorRect = textView.textView.layoutManager.rectForOffset(
                            windowPosition.range.location
                          ) else {
                        Self.logger.warning("showCompletions: cursor rect resolution failed")
                        self.endSession(generation: generation)
                        return
                    }

                    guard let items = self.itemsForLiveEditor(response, textView: textView, delegate: delegate) else {
                        Self.logger.debug("showCompletions: the answer no longer matches the text at the cursor")
                        self.endSessionOrAskAgain(
                            textView: textView,
                            delegate: delegate,
                            generation: generation,
                            showWindowOnParent: showWindowOnParent
                        )
                        return
                    }

                    let screenCursorRect = window.convertToScreen(
                        textView.textView.convert(cursorRect, to: nil)
                    )

                    self.items = items
                    self.resetSelection()
                    self.notifySelection()

                    guard self.requestGeneration == generation, self.activeTextView === textView else {
                        return
                    }

                    showWindowOnParent(window, screenCursorRect)
                    self.isPresented = true
                    delegate.completionWindowDidShow(textView: textView, itemCount: items.count)
                    self.refreshIfOvertaken(response, textView: textView, delegate: delegate)
                }
            } catch {
                self.endSession(generation: generation)
                return
            }
        }
    }

    private func itemsForLiveEditor(
        _ response: CodeSuggestionResponse,
        textView: TextViewController,
        delegate: CodeSuggestionDelegate
    ) -> [CodeSuggestionEntry]? {
        guard let liveCursor = textView.cursorPositions.first,
              !response.prefix.isCurrent(at: liveCursor, in: textView) else {
            return response.items
        }
        guard let reranked = delegate.completionOnCursorMove(textView: textView, cursorPosition: liveCursor),
              !reranked.isEmpty else {
            return nil
        }
        return reranked
    }

    private func endSessionOrAskAgain(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        generation: Int,
        showWindowOnParent: @escaping @MainActor (NSWindow, NSRect) -> Void
    ) {
        guard requestGeneration == generation else { return }
        let asksAgain = lastDroppedMovePresents && !Task.isCancelled
        endSession()
        guard asksAgain, let liveCursor = textView.cursorPositions.first else { return }
        showCompletions(
            textView: textView,
            delegate: delegate,
            cursorPosition: liveCursor,
            showWindowOnParent: showWindowOnParent
        )
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
        lastDroppedMovePresents = false
        items.removeAll()
        resetSelection()
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
        presentIfNot: Bool = false,
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
            resetSelection()
            notifySelection()
            // A deletion arrives here as a plain move, so the delegate, not the trigger, decides. One refresh runs at
            // a time: when it lands it asks again for the caret as it is then, so typing never stacks requests.
            if !isRefreshingItems, delegate.completionNeedsFreshItems(textView: textView, cursorPosition: position) {
                refreshItems(textView: textView, delegate: delegate, cursorPosition: position)
            }
            return
        }

        // A refresh only replaces what the window shows, so a move it cannot answer closes as if none were running.
        guard itemsRequestTask == nil || isRefreshingItems else {
            lastDroppedMovePresents = presentIfNot
            return
        }

        close()
    }

    // Closing first and asking again would blank the window on every keystroke while a partial pool narrows.
    private func refreshItems(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        cursorPosition: CursorPosition
    ) {
        itemsRequestTask?.cancel()
        requestGeneration &+= 1
        let generation = requestGeneration
        refreshGeneration = generation
        itemsRequestTask = Task {
            defer {
                if self.requestGeneration == generation {
                    self.itemsRequestTask = nil
                }
            }

            let response = await delegate.completionSuggestionsRequested(
                textView: textView,
                cursorPosition: cursorPosition,
                isManualTrigger: false
            )
            guard self.requestGeneration == generation, !Task.isCancelled,
                  self.isPresented, self.activeTextView === textView else { return }

            guard let response else {
                // Nothing for the prefix it ran on; a key typed meanwhile may still have answers. Only the range says
                // the caret moved: a typed key reports no line or column, and the editor's own position has both.
                if let liveCursor = textView.cursorPositions.first, liveCursor.range != cursorPosition.range,
                   delegate.completionNeedsFreshItems(textView: textView, cursorPosition: liveCursor) {
                    self.refreshItems(textView: textView, delegate: delegate, cursorPosition: liveCursor)
                } else {
                    self.onRequestClose?()
                }
                return
            }
            guard let items = self.itemsForLiveEditor(response, textView: textView, delegate: delegate),
                  !items.isEmpty else {
                // A key typed while this ran can leave a prefix the window still answers but this pool does not.
                if let liveCursor = textView.cursorPositions.first,
                   !response.prefix.isCurrent(at: liveCursor, in: textView) {
                    self.refreshItems(textView: textView, delegate: delegate, cursorPosition: liveCursor)
                } else {
                    self.onRequestClose?()
                }
                return
            }

            let chosen = self.selectionIsChosen && self.rowIDs.indices.contains(self.selectedIndex)
                ? self.rowIDs[self.selectedIndex] : nil
            self.items = items
            if let chosen, let index = self.rowIDs.firstIndex(of: chosen) {
                self.selectedIndex = index
            } else {
                self.resetSelection()
            }
            self.notifySelection()
            delegate.completionWindowDidShow(textView: textView, itemCount: items.count)
            self.refreshIfOvertaken(response, textView: textView, delegate: delegate)
        }
    }

    // Text changed while a request ran, and the pool it left cannot answer what is there now.
    private func refreshIfOvertaken(
        _ response: CodeSuggestionResponse,
        textView: TextViewController,
        delegate: CodeSuggestionDelegate
    ) {
        guard let liveCursor = textView.cursorPositions.first,
              !response.prefix.isCurrent(at: liveCursor, in: textView),
              delegate.completionNeedsFreshItems(textView: textView, cursorPosition: liveCursor)
        else { return }
        refreshItems(textView: textView, delegate: delegate, cursorPosition: liveCursor)
    }

    private func resetSelection() {
        isResettingSelection = true
        selectedIndex = 0
        isResettingSelection = false
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
