//
//  AIEditorContextMenuTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct AIEditorContextMenuTests {
    private func builtMenu(
        availability: AIQueryActionAvailability,
        onAction: ((AIQueryAction) -> Void)? = { _ in }
    ) -> AIEditorContextMenu {
        let menu = AIEditorContextMenu(title: "")
        menu.fullText = { "SELECT 1" }
        menu.aiAvailability = { availability }
        menu.onAIAction = onAction
        menu.menuNeedsUpdate(menu)
        return menu
    }

    private func available(statement: Bool = true, provider: Bool = true) -> AIQueryActionAvailability {
        AIQueryActionAvailability(
            aiEnabled: true,
            hasActiveProvider: provider,
            connectionPolicy: .alwaysAllow,
            isQueryTab: true,
            isConnected: true,
            hasStatement: statement
        )
    }

    private var aiTitles: [String] {
        AIQueryAction.editorActions.map(\.menuTitle)
    }

    @Test("With a statement and nothing selected, Review, Explain and Optimize are all offered")
    func offeredWithoutSelection() {
        let titles = builtMenu(availability: available()).items.map(\.title)
        #expect(Array(titles.suffix(aiTitles.count)) == aiTitles)
    }

    @Test("Unavailable AI items are hidden rather than dimmed", arguments: [false, true])
    func hiddenWhenUnavailable(missingProvider: Bool) {
        let availability = missingProvider ? available(provider: false) : .hidden
        let titles = builtMenu(availability: availability).items.map(\.title)
        #expect(titles.allSatisfy { !aiTitles.contains($0) })
    }

    @Test("AI items carry no key equivalent and dispatch their own action")
    func itemsDispatch() throws {
        var received: [AIQueryAction] = []
        let menu = builtMenu(availability: available()) { received.append($0) }
        let aiItems = menu.items.filter { aiTitles.contains($0.title) }
        #expect(aiItems.allSatisfy { $0.keyEquivalent.isEmpty })

        for item in aiItems {
            let action = try #require(item.action)
            NSApp.sendAction(action, to: item.target, from: item)
        }
        #expect(received == AIQueryAction.editorActions)
    }

    private func editorMenu(
        text: String = "SELECT id FROM users",
        foldState: Bool? = false,
        ai: AIQueryActionAvailability = .hidden,
        selection: EditorContextSelection = EditorContextSelection(
            selectedRange: NSRange(location: 0, length: 0),
            contextClickWord: nil
        ),
        onFormat: @escaping (NSRange) -> Void = { _ in },
        onFavorite: @escaping (String) -> Void = { _ in }
    ) -> AIEditorContextMenu {
        let menu = AIEditorContextMenu(title: "")
        menu.fullText = { text }
        menu.selection = { selection }
        menu.aiAvailability = { ai }
        menu.onAIAction = { _ in }
        menu.onFormatSQL = onFormat
        menu.onSaveAsFavorite = onFavorite
        menu.foldStateAtCursor = { foldState }
        menu.onToggleFold = {}
        menu.menuNeedsUpdate(menu)
        return menu
    }

    private func perform(_ title: String, in menu: AIEditorContextMenu) throws {
        let item = try #require(menu.items.first { $0.title == title })
        let action = try #require(item.action)
        NSApp.sendAction(action, to: item.target, from: item)
    }

    private func separatorsAreWellFormed(_ menu: NSMenu) -> Bool {
        let separators = menu.items.map { $0.isSeparatorItem }
        guard separators.first == false, separators.last == false else { return false }
        return !zip(separators, separators.dropFirst()).contains { $0 && $1 }
    }

    @Test("With every item available the groups are Edit, Select All, Format and Fold, Favorite, and AI")
    func fullMenuLayout() {
        let titles = editorMenu(ai: available()).items.map { $0.isSeparatorItem ? "-" : $0.title }
        let expected = ["Cut", "Copy", "Paste", "-", "Select All", "-", "Format SQL", "Fold", "-", "Save as Favorite…", "-"]
        #expect(titles == expected + aiTitles)
    }

    @Test("Format SQL and Save as Favorite are hidden rather than dimmed over an empty editor")
    func textItemsHiddenWhenEmpty() {
        let menu = editorMenu(text: "", foldState: nil)
        let titles = menu.items.map { $0.title }
        #expect(!titles.contains("Format SQL"))
        #expect(!titles.contains("Save as Favorite…"))
        #expect(menu.items.allSatisfy { $0.action != nil || $0.isSeparatorItem })
    }

    @Test("Fold is hidden rather than dimmed when the cursor is in no fold")
    func foldHiddenOutsideAFold() {
        let titles = editorMenu(foldState: nil).items.map { $0.title }
        #expect(!titles.contains("Fold"))
        #expect(!titles.contains("Unfold"))
        #expect(titles.contains("Format SQL"))
    }

    @Test("A collapsed fold offers Unfold")
    func collapsedFoldOffersUnfold() {
        let titles = editorMenu(foldState: true).items.map { $0.title }
        #expect(titles.contains("Unfold"))
        #expect(!titles.contains("Fold"))
    }

    @Test("Hidden items never leave a doubled, leading or trailing separator")
    func separatorsStayWellFormed() {
        for text in ["SELECT 1", ""] {
            for foldState in [false, nil] as [Bool?] {
                for ai in [available(), .hidden] {
                    let menu = editorMenu(text: text, foldState: foldState, ai: ai)
                    #expect(separatorsAreWellFormed(menu), "text: \(text.isEmpty ? "none" : text), fold: \(String(describing: foldState))")
                }
            }
        }
    }

    @Test("Format SQL after a right-click on a word formats as if nothing were selected")
    func formatIgnoresTheClickedWord() throws {
        let word = NSRange(location: 10, length: 4)
        var formatted: [NSRange] = []
        let menu = editorMenu(
            selection: EditorContextSelection(selectedRange: word, contextClickWord: word),
            onFormat: { formatted.append($0) }
        )

        try perform("Format SQL", in: menu)

        #expect(formatted == [NSRange(location: 10, length: 0)])
    }

    @Test("Format SQL keeps a selection the user made before right-clicking inside it")
    func formatKeepsAUserSelection() throws {
        let selection = NSRange(location: 0, length: 9)
        var formatted: [NSRange] = []
        let menu = editorMenu(
            selection: EditorContextSelection(selectedRange: selection, contextClickWord: nil),
            onFormat: { formatted.append($0) }
        )

        try perform("Format SQL", in: menu)

        #expect(formatted == [selection])
    }

    @Test("Save as Favorite after a right-click on a word saves the whole query, not the word")
    func favoriteIgnoresTheClickedWord() throws {
        let word = NSRange(location: 10, length: 4)
        var saved: [String] = []
        let menu = editorMenu(
            selection: EditorContextSelection(selectedRange: word, contextClickWord: word),
            onFavorite: { saved.append($0) }
        )

        try perform("Save as Favorite…", in: menu)

        #expect(saved == ["SELECT id FROM users"])
    }

    @Test("Save as Favorite keeps a selection the user made")
    func favoriteKeepsAUserSelection() throws {
        var saved: [String] = []
        let menu = editorMenu(
            selection: EditorContextSelection(selectedRange: NSRange(location: 0, length: 9), contextClickWord: nil),
            onFavorite: { saved.append($0) }
        )

        try perform("Save as Favorite…", in: menu)

        #expect(saved == ["SELECT id"])
    }
}
