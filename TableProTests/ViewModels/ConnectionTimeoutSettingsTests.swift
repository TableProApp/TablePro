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

    @Test("Customization loads both timeout overrides")
    func customizationLoadsTimeoutOverrides() {
        var connection = DatabaseConnection(name: "Timeouts")
        connection.connectTimeoutSeconds = 75
        connection.queryTimeoutSeconds = 180
        let viewModel = CustomizationPaneViewModel()

        viewModel.load(from: connection)

        #expect(viewModel.connectTimeoutSeconds == 75)
        #expect(viewModel.queryTimeoutSeconds == 180)
    }

    @Test("Connect timeout accepts only values from 1 through 600")
    func validatesConnectTimeout() {
        let viewModel = CustomizationPaneViewModel()

        viewModel.connectTimeoutSeconds = nil
        #expect(viewModel.validationIssues.isEmpty)

        viewModel.connectTimeoutSeconds = 0
        #expect(viewModel.validationIssues == ["Connect timeout must be between 1 and 600 seconds."])

        viewModel.connectTimeoutSeconds = 600
        #expect(viewModel.validationIssues.isEmpty)

        viewModel.connectTimeoutSeconds = 601
        #expect(viewModel.validationIssues == ["Connect timeout must be between 1 and 600 seconds."])
    }

    @Test("Query timeout accepts inheritance, no limit, and positive values")
    func validatesQueryTimeout() {
        let viewModel = CustomizationPaneViewModel()

        viewModel.queryTimeoutSeconds = nil
        #expect(viewModel.validationIssues.isEmpty)

        viewModel.queryTimeoutSeconds = 0
        #expect(viewModel.validationIssues.isEmpty)

        viewModel.queryTimeoutSeconds = 120
        #expect(viewModel.validationIssues.isEmpty)

        viewModel.queryTimeoutSeconds = -1
        #expect(viewModel.validationIssues == ["Query timeout must be 0 seconds or longer."])
    }

    @Test("Connection form edits include both timeout overrides")
    func coordinatorBuildsTimeoutEdits() {
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        coordinator.customization.connectTimeoutSeconds = 90
        coordinator.customization.queryTimeoutSeconds = 0

        let edits = coordinator.buildEdits()

        #expect(edits.connectTimeoutSeconds == 90)
        #expect(edits.queryTimeoutSeconds == 0)
    }
}
