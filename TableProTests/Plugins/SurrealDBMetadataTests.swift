//
//  SurrealDBMetadataTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("SurrealDB - registry metadata")
@MainActor
struct SurrealDBMetadataTests {
    private var snapshot: PluginMetadataSnapshot? {
        PluginMetadataRegistry.shared.snapshot(forTypeId: "SurrealDB")
    }

    @Test("SurrealDB is offered before the plugin is installed")
    func seeded() throws {
        let snapshot = try #require(snapshot)
        #expect(snapshot.displayName == "SurrealDB")
        #expect(snapshot.defaultPort == 8_000)
        #expect(snapshot.iconName == "surrealdb-icon")
        #expect(snapshot.isDownloadable)
        #expect(DatabaseType.allKnownTypes.contains(.surrealdb))
    }

    @Test("A SurrealDB namespace maps to the database level and a database to the schema level")
    func hierarchy() throws {
        let snapshot = try #require(snapshot)
        #expect(snapshot.schema.containerEntityName == "Namespace")
        #expect(snapshot.schema.schemaEntityName == "Database")
        #expect(snapshot.schema.databaseGroupingStrategy == .bySchema)
        #expect(snapshot.supportsDatabaseSwitching)
        #expect(snapshot.capabilities.supportsSchemaSwitching)
    }

    @Test("The record id is the primary key and cannot be edited")
    func recordIdentity() throws {
        let snapshot = try #require(snapshot)
        #expect(snapshot.schema.defaultPrimaryKeyColumn == "id")
        #expect(snapshot.schema.immutableColumns == ["id"])
    }

    @Test("The schema entity name defaults to Schema for every other driver")
    func schemaEntityNameDefault() {
        #expect(PluginManager.shared.schemaEntityName(for: .postgresql) == "Schema")
        #expect(PluginManager.shared.schemaEntityName(for: .surrealdb) == "Database")
    }

    @Test("The connection form and the plugin bundle declare the same fields")
    func connectionFieldsMatch() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let seeded = try encoder.encode(surrealDBConnectionFields())
        let declared = try encoder.encode(surrealDBPluginConnectionFields())

        #expect(
            seeded == declared,
            "The app seed and the plugin bundle must declare identical connection fields"
        )
    }

    @Test("The token field hides the built-in password, and nothing else does")
    func passwordHiding() {
        let fields = surrealDBPluginConnectionFields()
        let token = fields.first { $0.id == "sdbToken" }
        #expect(token?.hidesPassword == true)
        #expect(token?.visibleWhen?.values == ["token"])
        #expect(fields.filter(\.hidesPassword).count == 1)
    }

    @Test("The built-in database field is relabeled to Namespace, so there is no duplicate Database field")
    func namespaceIsTheBuiltInField() throws {
        // The top container is the namespace; the built-in database field carries it and is labeled from here.
        #expect(try #require(snapshot).schema.containerEntityName == "Namespace")

        // The custom Database field must not sit in the Connection section, or it collides with the built-in field.
        let database = try #require(surrealDBPluginConnectionFields().first { $0.id == "sdbDatabase" })
        #expect(database.section == .authentication)
        #expect(database.visibleWhen?.values == ["database", "record"])
    }
}
