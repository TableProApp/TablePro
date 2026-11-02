//
//  PromptedPasswordKeyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct PromptedPasswordKeyTests {
    @Test("A profile that asks every time asks once for every connection on it")
    func profileAnswerIsShared() {
        let profileId = UUID()
        var orders = DatabaseConnection(name: "Orders", host: "orders.example.com", type: .postgresql)
        orders.credentialMode = .profile(id: profileId)
        var billing = DatabaseConnection(name: "Billing", host: "billing.example.com", type: .postgresql)
        billing.credentialMode = .profile(id: profileId)

        #expect(DatabaseManager.promptCacheKey(for: orders) == DatabaseManager.promptCacheKey(for: billing))
    }

    @Test("A linked row whose file now names another server asks for the password again")
    func movedServerDoesNotReuseTheAnswer() {
        let linked = DatabaseConnection(name: "Shared", host: "es.team.example", port: 9_200, type: .elasticsearch)
        var moved = linked
        moved.additionalFields["esHosts"] = "es.attacker.example:9200"

        #expect(DatabaseManager.promptCacheKey(for: linked) != DatabaseManager.promptCacheKey(for: moved))
    }

    @Test("The prompt names the host the engine dials first, before a field it ignores")
    func summaryLeadsWithTheHost() {
        let connection = DatabaseConnection(
            name: "Orders",
            host: "attacker.example",
            port: 5_432,
            type: .postgresql,
            additionalFields: ["databaseUrl": "db.corp.internal:5432"]
        )

        #expect(connection.destinationSummary.hasPrefix("attacker.example:5432"))
    }

    @Test("The prompt names every host-list entry after the host, with no count standing in for them")
    func summaryNamesEveryHostListEntry() {
        let connection = DatabaseConnection(
            name: "Production",
            host: "es.prod.internal",
            port: 9_200,
            type: .elasticsearch,
            additionalFields: ["esHosts": "es.corp.internal:9200, attacker.example:9200"]
        )

        let summary = connection.destinationSummary

        #expect(summary.hasPrefix("es.prod.internal:9200"))
        #expect(summary.contains("es.corp.internal:9200"))
        #expect(summary.contains("attacker.example:9200"))
        #expect(!summary.contains("more"))
    }

    @Test("A Snowflake account on another engine is not named")
    func snowflakeAccountOnlyForSnowflake() {
        let connection = DatabaseConnection(
            name: "Production",
            host: "es.prod.internal",
            port: 9_200,
            type: .elasticsearch,
            additionalFields: ["snowflakeAccount": "decoy-account"]
        )

        #expect(!connection.destinationSummary.contains("decoy-account"))
    }
}
