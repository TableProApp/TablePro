//
//  SuggestionViewModel.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/22/25.
//

import AppKit

@MainActor
final class SuggestionViewModel: ObservableObject {
    /// The items to be displayed in the window
    @Published var items: [CodeSuggestionEntry] = []
    var itemsRequestTask: Task<Void, Never>?
    weak var activeTextView: TextViewController?

    weak var delegate: CodeSuggestionDelegate?

    private var cursorPosition: CursorPosition?
    private var syntaxHighlightedCache: [Int: NSAttributedString] = [:]

    func showCompletions(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        cursorPosition: CursorPosition,
        showWindowOnParent: @escaping @MainActor (NSWindow, NSRect) -> Void
    ) {
        self.activeTextView = nil
        self.delegate = nil
        itemsRequestTask?.cancel()

        guard let targetParentWindow = textView.view.window else { return }

        self.activeTextView = textView
        self.delegate = delegate
        itemsRequestTask = Task {
            defer { itemsRequestTask = nil }

            do {
                guard let completionItems = await delegate.completionSuggestionsRequested(
                    textView: textView,
                    cursorPosition: cursorPosition
                ) else {
                    return
                }

                try Task.checkCancellation()
                try await MainActor.run {
                    try Task.checkCancellation()

                    guard let cursorPosition = textView.resolveCursorPosition(completionItems.windowPosition),
                          let cursorRect = textView.textView.layoutManager.rectForOffset(
                            cursorPosition.range.location
                          ),
                          let cursorRect = textView.view.window?.convertToScreen(
                            textView.textView.convert(cursorRect, to: nil)
                          ) else {
                        return
                    }

                    self.items = completionItems.items
                    self.syntaxHighlightedCache = [:]
                    showWindowOnParent(targetParentWindow, cursorRect)
                }
            } catch {
                return
            }
        }
    }

    func cursorsUpdated(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        position: CursorPosition,
        close: () -> Void
    ) {
        guard itemsRequestTask == nil else { return }

        if activeTextView !== textView {
            close()
            return
        }

        guard let newItems = delegate.completionOnCursorMove(
            textView: textView,
            cursorPosition: position
        ),
              !newItems.isEmpty else {
            close()
            return
        }

        items = newItems
    }

    func didSelect(item: CodeSuggestionEntry) {
        delegate?.completionWindowDidSelect(item: item)
    }

    func applySelectedItem(item: CodeSuggestionEntry, window: NSWindow?) {
        guard let activeTextView else {
            return
        }
        self.delegate?.completionWindowApplyCompletion(
            item: item,
            textView: activeTextView,
            cursorPosition: activeTextView.cursorPositions.first
        )
        window?.close()
    }

    func willClose() {
        items.removeAll()
        activeTextView = nil
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
