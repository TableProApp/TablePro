//
//  ChatContentWidthTests.swift
//  TableProTests
//
//  The chat panel is one view with two widths: it fills the 270pt trailing pane it was measured in,
//  and takes a reading measure in Agent mode, where the same view is the window's content column and
//  filling it ran a line the whole width of the window.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Chat content width")
@MainActor
struct ChatContentWidthTests {
    @Test("A pane conversation is capped at nothing and a reading one at a column")
    func widthsAreWhatTheyClaim() {
        #expect(ChatContentWidth.pane.maxWidth == nil)
        #expect(ChatContentWidth.reading.maxWidth == 720)
    }

    /// The default is what keeps the trailing pane exactly as it was: every other caller of the panel
    /// passes nothing, and a `.reading` default would have capped a column that is already narrower
    /// than the cap and centred it in the gap.
    @Test("The panel fills its column unless it is asked for a reading measure")
    func theDefaultFillsThePane() {
        let connection = TestFixtures.makeConnection(type: .mysql)
        let sessionId = UUID()
        let viewModel = AIChatViewModel(services: .live, sessionId: sessionId, restoringConversation: nil)

        let pane = AIChatPanelView(connection: connection, viewModel: viewModel)
        let conversation = AIChatPanelView(connection: connection, viewModel: viewModel, contentWidth: .reading)

        #expect(pane.contentWidth == .pane)
        #expect(conversation.contentWidth == .reading)
    }
}
