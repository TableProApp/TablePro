//
//  PluginMetadataRegistryVariantTests.swift
//  TableProTests
//
//  A multi-type plugin (PostgreSQL serves Redshift, CockroachDB, PGlite) has one set of
//  Swift statics, so per-type facts live only in the curated built-in table. registerVariant
//  must keep the curated entry rather than overwrite it with the shared plugin snapshot.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("PluginMetadataRegistry variant registration", .serialized)
struct PluginMetadataRegistryVariantTests {
    @Test("keeps the curated port instead of the shared plugin's")
    func keepsCuratedPort() throws {
        let registry = PluginMetadataRegistry.shared
        let postgres = try #require(registry.snapshot(forTypeId: "PostgreSQL"))
        #expect(postgres.defaultPort == 5_432)

        registry.registerVariant(pluginSnapshot: postgres, forTypeId: "CockroachDB")

        #expect(registry.snapshot(forTypeId: "CockroachDB")?.defaultPort == 26_257)
    }

    @Test("keeps curated capabilities instead of the shared plugin's")
    func keepsCuratedCapabilities() throws {
        let registry = PluginMetadataRegistry.shared
        let postgres = try #require(registry.snapshot(forTypeId: "PostgreSQL"))
        #expect(postgres.capabilities.supportsAddColumn == true)

        registry.registerVariant(pluginSnapshot: postgres, forTypeId: "CockroachDB")

        #expect(registry.snapshot(forTypeId: "CockroachDB")?.capabilities.supportsAddColumn == false)
    }

    @Test("keeps PGlite's single-connection flag through registration")
    func keepsPGliteSingleConnection() throws {
        let registry = PluginMetadataRegistry.shared
        let postgres = try #require(registry.snapshot(forTypeId: "PostgreSQL"))
        #expect(postgres.capabilities.supportsConnectionPooling == true)

        registry.registerVariant(pluginSnapshot: postgres, forTypeId: "PGlite")

        #expect(registry.snapshot(forTypeId: "PGlite")?.capabilities.supportsConnectionPooling == false)
        #expect(registry.snapshot(forTypeId: "PGlite")?.connection.defaultHost == "127.0.0.1")
    }
}
