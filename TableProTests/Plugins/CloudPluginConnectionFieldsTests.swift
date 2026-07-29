//
//  CloudPluginConnectionFieldsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Cloud plugin connection fields")
struct CloudPluginConnectionFieldsTests {
    private func registrySnapshot(forTypeId typeId: String) throws -> PluginMetadataSnapshot {
        let defaults = PluginMetadataRegistry.shared.registryPluginDefaults()
        let entry = try #require(defaults.first { $0.typeId == typeId })
        return entry.snapshot
    }

    @Test("DynamoDB, BigQuery, and Snowflake never offer the built-in password")
    func cloudPluginsHideBuiltInPassword() throws {
        for typeId in ["DynamoDB", "BigQuery", "Snowflake"] {
            let snapshot = try registrySnapshot(forTypeId: typeId)
            #expect(snapshot.connection.hidesBuiltInPassword)
        }
    }
}
