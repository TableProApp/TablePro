//
//  QueryCommandAvailabilityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("QueryCommandAvailability")
struct QueryCommandAvailabilityTests {
    @Test("A connected tab with text can run, explain, format and favorite")
    func liveTab() {
        let commands = Self.make()

        #expect(commands.canRun)
        #expect(commands.canExplain)
        #expect(commands.canFormat)
        #expect(commands.canSaveAsFavorite)
        #expect(commands.canStop == false)
    }

    @Test("An empty editor offers nothing to run, explain, format or favorite")
    func emptyEditor() {
        let commands = Self.make(hasQueryText: false)

        #expect(commands.canRun == false)
        #expect(commands.canExplain == false)
        #expect(commands.canFormat == false)
        #expect(commands.canSaveAsFavorite == false)
        #expect(commands.canClearQuery == false)
    }

    /// Formatting rewrites text the reader already has. Gating it on the session made the one
    /// command that needs no server unavailable exactly when the server was the problem.
    @Test("Format and Favorite do not wait for a session")
    func formatIgnoresTheSession() {
        let commands = Self.make(isConnected: false)

        #expect(commands.canFormat)
        #expect(commands.canSaveAsFavorite)
        #expect(commands.canRun == false)
        #expect(commands.canExplain == false)
    }

    /// Run and Stop are one control, so they must never both be actionable or both be dead.
    @Test("Run and Stop are exactly one actionable control in every state")
    func runAndStopAreExclusive() {
        for isConnected in [true, false] {
            for hasText in [true, false] {
                for isExecuting in [true, false] {
                    let commands = Self.make(
                        isConnected: isConnected,
                        hasQueryText: hasText,
                        isExecuting: isExecuting
                    )
                    #expect(!(commands.canRun && commands.canStop))
                    if isExecuting {
                        #expect(commands.canStop)
                        #expect(commands.canRun == false)
                    }
                }
            }
        }
    }

    @Test("An engine that cannot explain does not offer Explain")
    func noExplainVariants() {
        let commands = Self.make(explainVariants: [])

        #expect(commands.canExplain == false)
        #expect(commands.explainHint.contains("does not explain"))
    }

    /// A dimmed control that does not say why is the one thing a reader cannot act on.
    @Test("A blocked command says why in its hint")
    func hintsExplainWhyBlocked() {
        #expect(Self.make(hasQueryText: false).runHint.contains("nothing to run"))
        #expect(Self.make(isExecuting: true).runHint.contains("already running"))
        #expect(Self.make(isConnected: false).runHint.contains("not available"))
        #expect(Self.make(hasQueryText: false).formatHint.contains("nothing to format"))
    }

    /// Clear Query leaves the results standing and takes `canRun` with it. Gating the whole Run
    /// menu on `canRun` then hid Clear Results at exactly the moment it was the live command.
    @Test("The Run menu stays reachable while a clear command is still valid")
    func runMenuOutlivesRun() {
        let clearedQueryWithResults = Self.make(hasQueryText: false, hasResults: true)
        #expect(clearedQueryWithResults.canRun == false)
        #expect(clearedQueryWithResults.canClearResults)
        #expect(clearedQueryWithResults.canOpenRunMenu)

        let offlineWithText = Self.make(isConnected: false, hasQueryText: true)
        #expect(offlineWithText.canRun == false)
        #expect(offlineWithText.canOpenRunMenu)

        let nothingAtAll = Self.make(hasQueryText: false, hasResults: false)
        #expect(nothingAtAll.canOpenRunMenu == false)
    }

    @Test("Clear Results follows the results, not the query text")
    func clearResultsFollowsResults() {
        #expect(Self.make(hasResults: true).canClearResults)
        #expect(Self.make(hasResults: false).canClearResults == false)
        #expect(Self.make(hasQueryText: false, hasResults: true).canClearResults)
    }

    private static func make(
        isConnected: Bool = true,
        hasQueryText: Bool = true,
        isExecuting: Bool = false,
        hasResults: Bool = true,
        explainVariants: [ExplainVariant] = [ExplainVariant(id: "plain", label: "Explain", sqlPrefix: "EXPLAIN")]
    ) -> QueryCommandAvailability {
        QueryCommandAvailability(
            isConnected: isConnected,
            hasQueryText: hasQueryText,
            isExecuting: isExecuting,
            hasResults: hasResults,
            explainVariants: explainVariants,
            shortcutHint: { label, _ in label }
        )
    }
}
