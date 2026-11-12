//
//  QueryTabMoveConfirmationTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@MainActor
struct QueryTabMoveConfirmationTests {
    private static let productionTag = ConnectionTag(name: "production", isPreset: true, color: .red)

    private static func confirmation(
        tags: [ConnectionTag] = [],
        level: SafeModeLevel = .silent
    ) -> QueryTabMoveConfirmation {
        var target = TestFixtures.makeConnection(name: "Orders")
        target.safeModeLevel = level
        return QueryTabMoveConfirmation(tabTitle: "Query 1", sourceName: "Shop", target: target, targetTags: tags)
    }

    @Test("The question names the tab, the connection it leaves and the one it moves to")
    func namesTheTabAndTheTarget() {
        let plain = Self.confirmation()

        #expect(plain.title.contains("Query 1"))
        #expect(plain.title.contains("Orders"))
        #expect(plain.message.contains("Shop"))
        #expect(plain.message.contains("Orders"))
        #expect(!plain.cancelIsDefault)
    }

    @Test("An ordinary target asks with Move as the default and Escape on Cancel")
    func ordinaryTargetDefaultsToMove() {
        let (alert, moveResponse) = Self.confirmation().makeAlert()

        #expect(alert.buttons.map { $0.title } == [String(localized: "Move"), String(localized: "Cancel")])
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[1].keyEquivalent == "\u{1B}")
        #expect(moveResponse == .alertFirstButtonReturn)
        #expect(alert.alertStyle == .informational)
    }

    @Test("A target tagged production says so, and Return cancels there")
    func productionTargetDefaultsToCancel() {
        let marked = Self.confirmation(tags: [ConnectionTag(name: "local"), Self.productionTag])
        let (alert, moveResponse) = marked.makeAlert()

        #expect(marked.message.contains("production"))
        #expect(marked.cancelIsDefault)
        #expect(alert.buttons.map { $0.title } == [String(localized: "Cancel"), String(localized: "Move")])
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[1].keyEquivalent.isEmpty)
        #expect(moveResponse == .alertSecondButtonReturn)
        #expect(alert.alertStyle == .warning)
    }

    @Test("A target held to a Safe Mode level names the level, and Return cancels there")
    func safeModeTargetDefaultsToCancel() {
        let marked = Self.confirmation(level: .safeMode)

        #expect(marked.message.contains(SafeModeLevel.safeMode.displayName))
        #expect(marked.cancelIsDefault)
        #expect(marked.makeAlert().moveResponse == .alertSecondButtonReturn)
    }

    @Test("A tag only matches production by its name", arguments: [
        ("production", true), (" Production ", true), ("prod", false), ("development", false),
    ])
    func productionTagMatch(name: String, matches: Bool) {
        #expect(QueryTabMoveConfirmation.isProductionTag(ConnectionTag(name: name)) == matches)
    }
}

extension GlobalStateSuites {
    /// The coordinator reads the target from the connection library, so the saved list is swapped for the case.
    @MainActor
    struct QueryBarMoveConfirmationTests {
        private static let productionTagId = UUID(uuidString: "00000000-0000-0000-0000-000000000003")

        private final class Questions {
            var asked: [QueryTabMoveConfirmation] = []
        }

        @Test("A pick in the query bar asks the coordinator's question about the saved target before anything moves")
        func pickAsksAboutTheSavedTarget() async throws {
            var target = TestFixtures.makeConnection(name: "Orders Live")
            target.tagIds = try [#require(Self.productionTagId)]
            let saved = ConnectionStorage.shared.loadConnections()
            ConnectionStorage.shared.saveConnections(saved + [target])
            defer { ConnectionStorage.shared.saveConnections(saved) }

            let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(name: "Shop"))
            let tab = fixture.addTab(QueryTab(title: "Monthly totals", tabType: .query))
            let questions = Questions()
            fixture.coordinator.askToMoveQueryTab = { confirmation, _ in
                questions.asked.append(confirmation)
                return false
            }
            let picker = fixture.coordinator.queryBarTwoRowInput(forTab: tab.id).connection
            #expect(picker.canMove)

            await picker.choose(target.id)
            await picker.choose(fixture.connection.id)

            #expect(questions.asked.count == 1, "The connection the tab is on asks nothing")
            let question = try #require(questions.asked.first)
            #expect(question.title.contains("Monthly totals"))
            #expect(question.title.contains("Orders Live"))
            #expect(question.message.contains("Shop"))
            #expect(question.cancelIsDefault, "The target carries the production tag")
            #expect(fixture.tabManager.tabs.map { $0.id } == [tab.id])
        }

        @Test("A target no longer in the library asks nothing and moves nothing")
        func unknownTargetAsksNothing() async {
            let fixture = CoordinatorFixture()
            let tab = fixture.addTab(QueryTab(title: "Query 1", tabType: .query))
            let questions = Questions()
            fixture.coordinator.askToMoveQueryTab = { confirmation, _ in
                questions.asked.append(confirmation)
                return true
            }

            let confirmed = await fixture.coordinator.confirmQueryTabMove(tab.id, to: UUID())

            #expect(!confirmed)
            #expect(questions.asked.isEmpty)
        }
    }
}
