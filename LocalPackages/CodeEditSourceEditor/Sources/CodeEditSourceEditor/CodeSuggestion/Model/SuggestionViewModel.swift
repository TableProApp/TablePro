//
//  SuggestionViewModel.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/22/25.
//

import AppKit
import os

@MainActor
final class SuggestionViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SuggestionVM")
    /// The items to be displayed in the window
    @Published var items: [CodeSuggestionEntry] = []
    @Published var selectedIndex: Int = 0
    @Published var themeBackground: NSColor = .windowBackgroundColor
    @Published var themeTextColor: NSColor = .labelColor

    var itemsRequestTask: Task<Void, Never>?
    weak var activeTextView: TextViewController?

    weak var delegate: CodeSuggestionDelegate?

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
        self.activeTextView = nil
        self.delegate = nil
        itemsRequestTask?.cancel()

        guard let targetParentWindow = textView.view.window else {
            Self.logger.warning("showCompletions: textView.view.window is nil")
            return
        }

        self.activeTextView = textView
        self.delegate = delegate
        itemsRequestTask = Task {
            defer { itemsRequestTask = nil }

            do {
                guard let completionItems = await delegate.completionSuggestionsRequested(
                    textView: textView,
                    cursorPosition: cursorPosition,
                    isManualTrigger: isManualTrigger
                ) else {
                    Self.logger.debug("showCompletions: delegate returned nil items")
                    return
                }

                Self.logger.debug("showCompletions: got \(completionItems.items.count) items")

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
                        Self.logger.warning("showCompletions: cursor rect resolution failed")
                        return
                    }

                    self.items = completionItems.items
                    self.selectedIndex = 0
                    self.syntaxHighlightedCache = [:]
                    self.notifySelection()
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
        if itemsRequestTask != nil {
            itemsRequestTask?.cancel()
            itemsRequestTask = nil
        }

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
        selectedIndex = 0
        syntaxHighlightedCache = [:]
        notifySelection()
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
        itemsRequestTask?.cancel()
        itemsRequestTask = nil
        items.removeAll()
        selectedIndex = 0
        activeTextView = nil
        delegate = nil
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
