//
//  PluginDocumentEditingCapabilityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class DocumentEditingMongoDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock MongoDB"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "A MongoDB plugin built with document editing"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "MongoDB"
    static let databaseDisplayName = "MongoDB"
    static let iconName = "mongodb-icon"
    static let defaultPort = 27_017
    static let supportsDocumentEditing = true

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class PreDocumentEditingMongoDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock MongoDB"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "A MongoDB plugin built before document editing existed"
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
struct PluginDocumentEditingCapabilityTests {
    @Test("A plugin that writes whole documents offers Insert Document once it loads")
    func declaredCapabilityReachesTheSnapshot() {
        let built = PluginMetadataRegistry.shared.buildMetadataSnapshot(from: DocumentEditingMongoDBPlugin.self)
        #expect(built.capabilities.supportsDocumentEditing)
    }

    @Test("A plugin built before document writes existed does not offer Insert Document, whatever the curated entry says")
    func olderPluginOffersNothing() {
        let built = PluginMetadataRegistry.shared.buildMetadataSnapshot(from: PreDocumentEditingMongoDBPlugin.self)
        #expect(!built.capabilities.supportsDocumentEditing)
    }

    @Test("Engines that store rows do not offer Insert Document")
    func rowEnginesDoNotOffer() {
        #expect(!PluginManager.shared.supportsDocumentEditing(for: .postgresql))
        #expect(!PluginManager.shared.supportsDocumentEditing(for: .mysql))
    }
}
