//
//  AdvancedPaneViewModelTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@MainActor
struct AdvancedPaneViewModelTests {
    @Test("Loads external access from the connection")
    func loadsExternalAccessFromConnection() {
        let connection = DatabaseConnection(name: "Test", externalAccess: .readWrite)
        let viewModel = AdvancedPaneViewModel()

        viewModel.load(from: connection)

        #expect(viewModel.externalAccess == .readWrite)
    }

    @Test("Does not leak external access into plugin additional fields")
    func doesNotWriteExternalAccessIntoAdditionalFields() {
        let viewModel = AdvancedPaneViewModel()
        viewModel.externalAccess = .readWrite

        var fields: [String: String] = [:]
        viewModel.write(into: &fields)

        #expect(fields["externalAccess"] == nil)
    }

    @Test("Shows a Redis database index saved as db4 as the number the stepper takes")
    func loadsDbPrefixedRedisIndexAsANumber() throws {
        try #require(
            PluginManager.shared.additionalConnectionFields(for: .redis)
                .contains { $0.id == "redisDatabase" && $0.section == .advanced }
        )
        let connection = DatabaseConnection(
            name: "cache",
            type: .redis,
            additionalFields: ["redisDatabase": "db4"]
        )
        let viewModel = AdvancedPaneViewModel()

        viewModel.load(from: connection)

        #expect(viewModel.additionalFieldValues["redisDatabase"] == "4")
    }

    @Test("Shows the Redis database a synced connection names when no index was saved")
    func loadsRedisIndexFromTheDatabaseName() throws {
        try #require(
            PluginManager.shared.additionalConnectionFields(for: .redis)
                .contains { $0.id == "redisDatabase" && $0.section == .advanced }
        )
        let connection = DatabaseConnection(name: "cache", database: "db7", type: .redis)
        let viewModel = AdvancedPaneViewModel()

        viewModel.load(from: connection)

        #expect(viewModel.additionalFieldValues["redisDatabase"] == "7")
    }
}
