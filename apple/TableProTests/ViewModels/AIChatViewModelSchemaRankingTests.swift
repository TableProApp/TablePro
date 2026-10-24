//
//  AIChatViewModelSchemaRankingTests.swift
//  TableProTests
//

import Foundation
import os
@testable import TablePro
import Testing

@MainActor
struct AIChatViewModelSchemaRankingTests {
    @Test("Ranking the schema for a question runs off the main actor, and its order is kept")
    func rankingRunsOffTheMainActor() async {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let count = AppServices.live.appSettings.ai.maxSchemaTables + 5
        let fixture = await AIChatSchemaFixture.loaded(connection: connection, names: AIChatSchemaFixture.names(count: count))
        let vm = AIChatViewModel(services: fixture.services)
        vm.connection = connection
        let rankedOnMainThread = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        vm.schemaRanker = { _ in
            rankedOnMainThread.withLock { $0 = Thread.isMainThread }
            return ["table_007", "table_003"]
        }

        await vm.ensureSchemaLoaded(relevantTo: "recent orders")

        let onMainThread = rankedOnMainThread.withLock { $0 }
        #expect(onMainThread == false)
        #expect(vm.relevantTableNames == ["table_007", "table_003"])
    }

    @Test("A catalog that fits the prompt is not ranked")
    func smallCatalogIsNotRanked() async {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let fixture = await AIChatSchemaFixture.loaded(connection: connection, names: ["orders", "customers"])
        let vm = AIChatViewModel(services: fixture.services)
        vm.connection = connection
        let ranked = OSAllocatedUnfairLock(initialState: false)
        vm.schemaRanker = { _ in
            ranked.withLock { $0 = true }
            return ["customers"]
        }

        await vm.ensureSchemaLoaded(relevantTo: "orders")

        let didRank = ranked.withLock { $0 }
        #expect(!didRank)
        #expect(vm.relevantTableNames.isEmpty)
    }
}
