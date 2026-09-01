//
//  RightPanelTabAvailabilityTests.swift
//  TableProTests
//
//  The active tab is persisted per connection and restored without asking whether the tab still
//  exists, so a connection last left on AI Chat comes back to it with the assistant turned off.
//

import Foundation
import Testing

@testable import TablePro

@Suite("RightPanelTab availability")
struct RightPanelTabAvailabilityTests {
    @Test("AI Chat is the only tab a setting takes away")
    func aiChatIsTheOnlyOptionalTab() {
        #expect(RightPanelTab.available(isAIEnabled: true) == RightPanelTab.allCases)
        #expect(RightPanelTab.available(isAIEnabled: false) == [.details, .json])
    }

    @Test("A restored AI Chat tab resolves to Details while the assistant is off")
    func restoredAIChatFallsBack() {
        #expect(RightPanelTab.resolved(.aiChat, isAIEnabled: false) == .details)
        #expect(RightPanelTab.resolved(.aiChat, isAIEnabled: true) == .aiChat)
    }

    @Test("The tabs a setting cannot reach resolve to themselves either way")
    func alwaysAvailableTabsAreUntouched() {
        for enabled in [true, false] {
            #expect(RightPanelTab.resolved(.details, isAIEnabled: enabled) == .details)
            #expect(RightPanelTab.resolved(.json, isAIEnabled: enabled) == .json)
        }
    }

    @Test("A resolved tab is always one the picker offers")
    func resolutionIsAlwaysSelectable() {
        for enabled in [true, false] {
            for tab in RightPanelTab.allCases {
                let resolved = RightPanelTab.resolved(tab, isAIEnabled: enabled)
                #expect(RightPanelTab.available(isAIEnabled: enabled).contains(resolved))
            }
        }
    }
}
