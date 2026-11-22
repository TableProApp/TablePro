//
//  ConnectionTimeoutSettingsTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
struct ConnectionTimeoutSettingsTests {
    @Test("Database connection stores timeout overrides in reserved fields")
    func modelStoresTimeoutOverrides() {
        var connection = DatabaseConnection(name: "Timeouts")

        connection.connectTimeoutSeconds = 45
        connection.queryTimeoutSeconds = 0

        #expect(connection.connectTimeoutSeconds == 45)
        #expect(connection.queryTimeoutSeconds == 0)
        #expect(connection.additionalFields[DatabaseConnection.connectTimeoutSecondsKey] == "45")
        #expect(connection.additionalFields[DatabaseConnection.queryTimeoutSecondsKey] == "0")

        connection.connectTimeoutSeconds = nil
        connection.queryTimeoutSeconds = nil

        #expect(connection.additionalFields[DatabaseConnection.connectTimeoutSecondsKey] == nil)
        #expect(connection.additionalFields[DatabaseConnection.queryTimeoutSecondsKey] == nil)
    }

    @Test("Database connection rejects query timeouts unsafe for millisecond APIs")
    func modelRejectsUnsafeQueryTimeouts() {
        let maximum = DatabaseConnection.queryTimeoutSecondsRange.upperBound
        var connection = DatabaseConnection(name: "Timeouts")

        connection.queryTimeoutSeconds = maximum
        #expect(connection.queryTimeoutSeconds == maximum)
        #expect(connection.additionalFields[DatabaseConnection.queryTimeoutSecondsKey] == String(maximum))

        connection.queryTimeoutSeconds = maximum + 1
        #expect(connection.queryTimeoutSeconds == nil)
        #expect(connection.additionalFields[DatabaseConnection.queryTimeoutSecondsKey] == nil)

        connection.additionalFields[DatabaseConnection.queryTimeoutSecondsKey] = String(maximum + 1)
        #expect(connection.queryTimeoutSeconds == nil)
    }

    @Test("Kafka timeout storage migrates from the retired plugin field")
    func kafkaTimeoutStorageMigrates() {
        var connection = DatabaseConnection(name: "Kafka", type: .kafka)
        connection.additionalFields["kafkaConnectTimeout"] = "12"

        #expect(connection.connectTimeoutSeconds == 12)

        connection.additionalFields[DatabaseConnection.connectTimeoutSecondsKey] = "45"
        #expect(connection.connectTimeoutSeconds == 45)

        connection.additionalFields[DatabaseConnection.connectTimeoutSecondsKey] = "invalid"
        #expect(connection.connectTimeoutSeconds == nil)

        connection.connectTimeoutSeconds = 60
        #expect(connection.additionalFields[DatabaseConnection.connectTimeoutSecondsKey] == "60")
        #expect(connection.additionalFields["kafkaConnectTimeout"] == nil)

        connection.additionalFields["kafkaConnectTimeout"] = "12"
        connection.connectTimeoutSeconds = nil
        #expect(connection.additionalFields[DatabaseConnection.connectTimeoutSecondsKey] == nil)
        #expect(connection.additionalFields["kafkaConnectTimeout"] == nil)
    }

    @Test("Timeout overrides survive the saved connection encoding")
    func timeoutOverridesRoundTripThroughCodable() throws {
        var connection = DatabaseConnection(name: "Timeouts")
        connection.connectTimeoutSeconds = 45
        connection.queryTimeoutSeconds = 0

        let data = try JSONEncoder().encode(connection)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)

        #expect(decoded.connectTimeoutSeconds == 45)
        #expect(decoded.queryTimeoutSeconds == 0)
    }

    private func traits(_ type: DatabaseType = .mysql) -> ConnectionTypeTraits {
        ConnectionTypeTraits.live(for: type, pluginManager: .shared)
    }

    private func advancedIssues(_ draft: ConnectionDraft) -> [String] {
        ConnectionEditorEngine.issues(draft, traits(draft.type), EditorContext())
            .filter { $0.facet == .advanced }
            .map(\.message)
    }

    private func namedDraft() -> ConnectionDraft {
        var draft = ConnectionDraft.new(type: .mysql, traits: traits())
        draft.name = "Timeouts"
        return draft
    }

    @Test("Customization loads both timeout overrides")
    func customizationLoadsTimeoutOverrides() {
        var connection = DatabaseConnection(name: "Timeouts")
        connection.connectTimeoutSeconds = 75
        connection.queryTimeoutSeconds = 180

        let draft = ConnectionDraft.loaded(from: connection, secrets: .none, traits: traits(connection.type))

        #expect(draft.options.connectTimeoutSeconds == 75)
        #expect(draft.options.queryTimeoutSeconds == 180)
    }

    @Test("Connect timeout accepts only values from 1 through 600")
    func validatesConnectTimeout() {
        var draft = namedDraft()

        draft.options.connectTimeoutSeconds = nil
        #expect(advancedIssues(draft).isEmpty)

        draft.options.connectTimeoutSeconds = 0
        #expect(advancedIssues(draft) == ["Connect timeout must be between 1 and 600 seconds."])

        draft.options.connectTimeoutSeconds = 600
        #expect(advancedIssues(draft).isEmpty)

        draft.options.connectTimeoutSeconds = 601
        #expect(advancedIssues(draft) == ["Connect timeout must be between 1 and 600 seconds."])
    }

    @Test("Query timeout accepts only values safe for millisecond APIs")
    func validatesQueryTimeout() {
        var draft = namedDraft()
        let maximum = DatabaseConnection.queryTimeoutSecondsRange.upperBound

        draft.options.queryTimeoutSeconds = nil
        #expect(advancedIssues(draft).isEmpty)

        draft.options.queryTimeoutSeconds = 0
        #expect(advancedIssues(draft).isEmpty)

        draft.options.queryTimeoutSeconds = 120
        #expect(advancedIssues(draft).isEmpty)

        draft.options.queryTimeoutSeconds = maximum
        #expect(advancedIssues(draft).isEmpty)

        draft.options.queryTimeoutSeconds = maximum + 1
        #expect(advancedIssues(draft) == ["Query timeout must be between 0 and 2,147,483 seconds."])

        draft.options.queryTimeoutSeconds = -1
        #expect(advancedIssues(draft) == ["Query timeout must be between 0 and 2,147,483 seconds."])
    }

    @Test("Connection form edits include both timeout overrides")
    func coordinatorBuildsTimeoutEdits() {
        var draft = namedDraft()
        draft.options.connectTimeoutSeconds = 90
        draft.options.queryTimeoutSeconds = 0

        let edits = ConnectionEditorEngine.edits(draft, traits(), originalTraits: nil, EditorContext())

        #expect(edits.connectTimeoutSeconds == 90)
        #expect(edits.queryTimeoutSeconds == 0)
    }
}
