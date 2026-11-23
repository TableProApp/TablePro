//
//  ConnectionEditorEngineDatabaseFieldTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

// The editor must never require a database value it does not render, and must agree with the catalog adoption.
@MainActor
struct ConnectionEditorEngineDatabaseFieldTests {
    private func traits(_ type: DatabaseType) -> ConnectionTypeTraits {
        ConnectionTypeTraits.live(for: type, pluginManager: .shared)
    }

    private func newDraft(_ type: DatabaseType, name: String = "") -> ConnectionDraft {
        var draft = ConnectionDraft.new(type: type, traits: traits(type))
        draft.name = name
        return draft
    }

    private func rendersDatabase(_ type: DatabaseType) -> Bool {
        let traits = traits(type)
        let layout = ConnectionEditorEngine.layout(newDraft(type), traits, EditorContext())
        let rendered = layout.contains(.builtIn(.database))
        #expect(rendered == traits.showsBuiltInDatabaseField, "\(type.rawValue)")
        return rendered
    }

    // The built-in rows of General's identity and connection sections, the ones the old Network pane validated.
    private func connectionIssues(_ draft: ConnectionDraft) -> [FieldIssue] {
        let traits = traits(draft.type)
        let layout = ConnectionEditorEngine.layout(draft, traits, EditorContext())
        let rows = (layout.facet(.general)?.sections ?? [])
            .filter { $0.id == "identity" || $0.id == "connection" }
            .flatMap(\.rows)
            .filter { $0.pluginFieldID == nil }
        return ConnectionEditorEngine.issues(draft, traits, EditorContext(), layout: layout)
            .filter { rows.contains($0.row) }
    }

    // Issue #2234: gated on requiresAuthentication, which MongoDB declares false, the field was missing for MongoDB.
    @Test(
        "A network driver that takes a container name renders the field",
        arguments: [
            DatabaseType.mongodb,
            DatabaseType.cassandra,
            DatabaseType(rawValue: "Trino"),
            DatabaseType.mysql,
            DatabaseType.postgresql,
        ]
    )
    func networkDriversRenderTheField(type: DatabaseType) {
        #expect(rendersDatabase(type))
    }

    // Oracle and Dameng show a Schema field while declaring supportsDatabaseSwitching false.
    @Test(
        "A network driver without runtime database switching keeps its field",
        arguments: [DatabaseType.oracle, DatabaseType.dameng]
    )
    func networkDriversWithoutSwitchingKeepTheField(type: DatabaseType) {
        #expect(rendersDatabase(type))
    }

    @Test(
        "A driver that names its container elsewhere, or has none, opts out",
        arguments: [DatabaseType.redis, DatabaseType.etcd, DatabaseType.elasticsearch]
    )
    func optedOutDriversHideTheField(type: DatabaseType) {
        #expect(!rendersDatabase(type))
    }

    @Test(
        "An apiOnly driver without database switching keeps the field hidden",
        arguments: [DatabaseType.bigQuery, DatabaseType.dynamodb, DatabaseType.libsql]
    )
    func apiOnlyDriversWithoutSwitchingHideTheField(type: DatabaseType) {
        #expect(!rendersDatabase(type))
    }

    // A new DuckDB connection once demanded a database name the form had no field for, so Save stayed off forever.
    @Test("DuckDB neither renders nor requires the built-in database field")
    func duckDBIsSaveable() {
        #expect(!rendersDatabase(.duckdb))
        #expect(!ConnectionDatabaseRequirement.requiresValue(for: .duckdb))
        let issues = connectionIssues(newDraft(.duckdb, name: "Analytics"))
        #expect(!issues.contains { $0.message.localizedCaseInsensitiveContains("database") })
    }

    @Test("A named database is optional for a network driver, so a blank one still validates")
    func networkDatabaseStaysOptional() {
        var draft = newDraft(.mongodb, name: "Cluster")
        draft.database = ""
        #expect(rendersDatabase(.mongodb))
        #expect(!ConnectionDatabaseRequirement.requiresValue(for: .mongodb))
        #expect(!connectionIssues(draft).contains { $0.message.localizedCaseInsensitiveContains("database") })
    }

    @Test("Every type that requires a database value also renders a field for it, and the editor requires it too")
    func requiredImpliesRendered() {
        let types: [DatabaseType] = [
            .mysql, .postgresql, .mongodb, .cassandra, .oracle, .dameng,
            .redis, .etcd, .elasticsearch, .duckdb, .bigQuery, .dynamodb, .libsql,
        ]
        for type in types {
            let traits = traits(type)
            #expect(traits.showsBuiltInDatabaseField == ConnectionDatabaseRequirement.showsBuiltInField(for: type), "\(type.rawValue)")
            guard traits.connectionMode != .fileBased else { continue }
            let requires = ConnectionDatabaseRequirement.requiresValue(for: type)
            if requires {
                #expect(traits.showsBuiltInDatabaseField, "\(type.rawValue) requires a database it cannot render")
            }
            let blocks = ConnectionEditorEngine.issues(newDraft(type, name: "Probe"), traits, EditorContext())
                .contains { $0.row == .builtIn(.database) }
            #expect(blocks == requires, "\(type.rawValue)")
        }
    }
}
