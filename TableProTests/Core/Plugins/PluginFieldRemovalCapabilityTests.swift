//
//  PluginFieldRemovalCapabilityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class FieldRemovalMongoDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock MongoDB"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "A MongoDB plugin built with field removal"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "MongoDB"
    static let databaseDisplayName = "MongoDB"
    static let iconName = "mongodb-icon"
    static let defaultPort = 27_017
    static let supportsFieldRemoval = true

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class PreFieldRemovalMongoDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock MongoDB"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "A MongoDB plugin built before field removal existed"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "MongoDB"
    static let databaseDisplayName = "MongoDB"
    static let iconName = "mongodb-icon"
    static let defaultPort = 27_017

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

@MainActor
struct PluginFieldRemovalCapabilityTests {
    @Test("A plugin that removes fields offers Remove Field once it loads")
    func declaredCapabilityReachesTheSnapshot() {
        let built = PluginMetadataRegistry.shared.buildMetadataSnapshot(from: FieldRemovalMongoDBPlugin.self)
        #expect(built.capabilities.supportsFieldRemoval)
    }

    @Test("A plugin built before field removal existed offers none of it, whatever the curated entry says")
    func olderPluginOffersNothing() {
        let built = PluginMetadataRegistry.shared.buildMetadataSnapshot(from: PreFieldRemovalMongoDBPlugin.self)
        #expect(!built.capabilities.supportsFieldRemoval)
    }

    @Test("Only a document store tells a missing field from NULL")
    func onlyDocumentStoresOffer() {
        #expect(PluginManager.shared.supportsFieldRemoval(for: .mongodb))
        #expect(!PluginManager.shared.supportsFieldRemoval(for: .postgresql))
        #expect(!PluginManager.shared.supportsFieldRemoval(for: .mysql))
        #expect(!PluginManager.shared.supportsFieldRemoval(for: .sqlite))
    }

    @Test("A result's missing cells survive encoding, and a result from an older release decodes without them")
    func absentCellsRoundTrip() throws {
        var result = PluginQueryResult(
            columns: ["_id", "nick"], columnTypeNames: ["ObjectId", "String"],
            rows: [["1", .null]], rowsAffected: 0, timing: PluginQueryTiming(total: 0)
        )
        result.absentCells = [0: [1]]

        let decoded = try JSONDecoder().decode(PluginQueryResult.self, from: JSONEncoder().encode(result))
        #expect(decoded.absentCells == [0: [1]])

        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        json.removeValue(forKey: "absentCells")
        let older = try JSONDecoder().decode(PluginQueryResult.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(older.absentCells == nil)
    }
}
