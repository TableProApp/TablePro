//
//  AIEditorContextMenuTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
@Suite("Editor context menu AI group")
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
}
