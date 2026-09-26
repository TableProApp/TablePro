//
//  MongoDBStructureEditingParityTests.swift
//  TableProTests
//
//  The app describes MongoDB from a curated copy of the plugin's statics until the registry plugin
//  loads, and plugins never load under XCTest, so every Structure tab test reads the copy. The
//  plugin reads its flags from `MongoDBStructureEditing`, which is compiled into this target, so the
//  two are compared here instead of drifting until the plugin silently replaces one with the other.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct MongoDBStructureEditingParityTests {
    private func curated() throws -> PluginMetadataSnapshot {
        try #require(PluginMetadataRegistry.shared.builtInDefaults().first { $0.typeId == "MongoDB" }?.snapshot)
    }

    @Test("Structure capabilities match the plugin")
    func structureCapabilities() throws {
        let snapshot = try curated()

        #expect(snapshot.supportsSchemaEditing == MongoDBStructureEditing.supportsSchemaEditing)
        #expect(snapshot.capabilities.supportsAddColumn == MongoDBStructureEditing.supportsAddColumn)
        #expect(snapshot.capabilities.supportsModifyColumn == MongoDBStructureEditing.supportsModifyColumn)
        #expect(snapshot.capabilities.supportsDropColumn == MongoDBStructureEditing.supportsDropColumn)
        #expect(snapshot.capabilities.supportsAddIndex == MongoDBStructureEditing.supportsAddIndex)
        #expect(snapshot.capabilities.supportsDropIndex == MongoDBStructureEditing.supportsDropIndex)
    }

    @Test("The curated copy says a collection's columns are a sample")
    func columnsAreSampled() throws {
        #expect(try curated().capabilities.columnsAreSampled)
    }
}
