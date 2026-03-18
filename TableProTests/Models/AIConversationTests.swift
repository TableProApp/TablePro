//
//  AIConversationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AIConversation")
struct AIConversationTests {
    @Test("updateTitle truncates long content")
    func updateTitleTruncatesLongContent() {
        var conv = AIConversation(
            title: "",
            messages: [AIChatMessage(role: .user, content: String(repeating: "a", count: 60))]
        )
        conv.updateTitle()
        #expect(conv.title.hasSuffix("..."))
    }

    @Test("updateTitle keeps short content")
    func updateTitleKeepsShortContent() {
        var conv = AIConversation(
            title: "",
            messages: [AIChatMessage(role: .user, content: "Short query")]
        )
        conv.updateTitle()
        #expect(conv.title == "Short query")
    }
}
