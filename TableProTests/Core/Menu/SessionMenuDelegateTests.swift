//
//  SessionMenuDelegateTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

/// The two lists under File > Session are filled when they open, so what they put in the menu is
/// never seen by the suites that walk the built menu bar. These ask the delegates directly.
@MainActor
struct SessionMenuDelegateTests {
    private func makeRegistry() -> AgentSessionRegistry {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionMenuDelegateTests-\(UUID().uuidString)", isDirectory: true)
        return AgentSessionRegistry(store: AgentSessionStore(directory: directory))
    }

    /// An empty menu opens as a sliver with no text, which reads as a broken command, and the row
    /// that opens it cannot be dimmed through the responder chain: AppKit gives a submenu's row its
    /// own action. This is the state a launch with no connection window is in.
    @Test("An empty list names itself rather than opening with nothing in it")
    func emptyListsCarryAPlaceholder() {
        for delegate in [AgentSessionMenuDelegate() as NSMenuDelegate, ConversationHistoryMenuDelegate()] {
            let menu = NSMenu()
            menu.delegate = delegate
            delegate.menuNeedsUpdate?(menu)

            #expect(menu.items.count == 1)
            #expect(menu.items.first?.title == String(localized: "None Available"))
            #expect(menu.items.first?.isEnabled == false)
            #expect(menu.items.first?.action == nil)
        }
    }

    /// The session travels in `representedObject`, which is what `agentSessionTarget(for:)` reads to
    /// act on the session the row names rather than on the rail's highlight. A row with a target
    /// would skip the window's validation, and a row without the id would act on the wrong session.
    @Test("A session row names its session and leaves the responder chain to resolve it")
    func sessionRowCarriesItsSession() throws {
        let registry = makeRegistry()
        let session = try #require(registry.resolveSession(for: UUID(), startingIfNeeded: true))

        let row = AgentSessionMenuDelegate.item(for: session, isDisplayed: true)
        #expect(row.title == session.displayTitle)
        #expect(row.action == AgentSessionMenuDelegate.action)
        #expect(row.target == nil)
        #expect(row.representedObject as? UUID == session.id)
        #expect(row.state == .on)

        #expect(AgentSessionMenuDelegate.item(for: session, isDisplayed: false).state == .off)
    }

    /// A conversation is titled from its first exchange, so one nothing was sent in has no title and
    /// would otherwise draw a blank row.
    @Test("A conversation row falls back to a name when the conversation has none")
    func conversationRowNamesAnUntitledConversation() {
        let untitled = AIConversation(title: "")
        let named = AIConversation(title: "Late orders")

        #expect(ConversationHistoryMenuDelegate.item(for: untitled, isActive: false).title
            == String(localized: "Untitled"))
        #expect(ConversationHistoryMenuDelegate.item(for: named, isActive: true).title == "Late orders")
    }

    @Test("A conversation row names its conversation and carries the current one's tick")
    func conversationRowCarriesItsConversation() {
        let conversation = AIConversation(title: "Late orders")

        let row = ConversationHistoryMenuDelegate.item(for: conversation, isActive: true)
        #expect(row.action == ConversationHistoryMenuDelegate.action)
        #expect(row.target == nil)
        #expect(row.representedObject as? UUID == conversation.id)
        #expect(row.state == .on)

        #expect(ConversationHistoryMenuDelegate.item(for: conversation, isActive: false).state == .off)
    }
}
