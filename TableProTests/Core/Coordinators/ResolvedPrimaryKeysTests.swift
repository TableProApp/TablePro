//
//  ResolvedPrimaryKeysTests.swift
//  TableProTests
//
//  A reload after a structure change carried the tab's old primary key into the new result, so the
//  next edit was written against a key the table no longer had.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct ResolvedPrimaryKeysTests {
    @Test("The keys the result reports win over everything else")
    func reportedKeysWin() {
        let keys = QueryExecutionCoordinator.resolvedPrimaryKeys(
            reported: ["code"],
            engineDefault: "_id",
            previous: ["id"],
            definitionChanged: true
        )

        #expect(keys == ["code"])
    }

    @Test("An engine's own key answers when the result reports none")
    func engineDefaultAnswersNextEvenAfterADefinitionChange() {
        let keys = QueryExecutionCoordinator.resolvedPrimaryKeys(
            reported: [],
            engineDefault: "_id",
            previous: ["id"],
            definitionChanged: true
        )

        #expect(keys == ["_id"])
    }

    @Test("The tab's keys carry over while the definition is unchanged")
    func previousKeysCarryOverWhileTheDefinitionHolds() {
        let keys = QueryExecutionCoordinator.resolvedPrimaryKeys(
            reported: nil,
            engineDefault: nil,
            previous: ["id"],
            definitionChanged: false
        )

        #expect(keys == ["id"])
    }

    @Test("The tab's keys never carry over a definition change, so a dropped key stays dropped")
    func previousKeysNeverCarryOverADefinitionChange() {
        let droppedKey = QueryExecutionCoordinator.resolvedPrimaryKeys(
            reported: [],
            engineDefault: nil,
            previous: ["id"],
            definitionChanged: true
        )
        let unreadDefinition = QueryExecutionCoordinator.resolvedPrimaryKeys(
            reported: nil,
            engineDefault: nil,
            previous: ["id"],
            definitionChanged: true
        )

        #expect(droppedKey.isEmpty)
        #expect(unreadDefinition.isEmpty)
    }
}
