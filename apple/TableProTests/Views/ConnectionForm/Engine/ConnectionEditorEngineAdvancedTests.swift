//
//  ConnectionEditorEngineAdvancedTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorEngineAdvancedTests {
    private func traits(_ type: DatabaseType) -> ConnectionTypeTraits {
        ConnectionTypeTraits.live(for: type, pluginManager: .shared)
    }

    private func loaded(_ connection: DatabaseConnection) -> ConnectionDraft {
        ConnectionDraft.loaded(from: connection, secrets: .none, traits: traits(connection.type))
    }

    private func sqliteWithExtensionList() throws -> ConnectionTypeTraits {
        let sqlite = traits(.sqlite)
        try #require(sqlite.fields.contains { $0.content == .loadableExtensions })
        return sqlite
    }

    private func redisWithAdvancedIndex() throws -> ConnectionTypeTraits {
        let redis = traits(.redis)
        try #require(redis.fields.contains { $0.id == "redisDatabase" && $0.section == .advanced })
        return redis
    }

    @Test("Loads external access from the connection")
    func loadsExternalAccessFromConnection() {
        let draft = loaded(DatabaseConnection(name: "Test", externalAccess: .readWrite))
        #expect(draft.ai.externalAccess == .readWrite)
    }

    @Test("Does not leak external access into plugin additional fields")
    func doesNotWriteExternalAccessIntoAdditionalFields() {
        let mysql = traits(.mysql)
        var draft = ConnectionDraft.new(type: .mysql, traits: mysql)
        draft.ai.externalAccess = .readWrite

        let edits = ConnectionEditorEngine.edits(draft, mysql, originalTraits: nil, EditorContext())

        #expect(edits.externalAccess == .readWrite)
        #expect(edits.additionalFields["externalAccess"] == nil)
    }

    @Test("Lists the connection's always-allowed tools in name order with nothing forgotten")
    func loadsAlwaysAllowedTools() {
        let draft = loaded(DatabaseConnection(name: "Staging", aiAlwaysAllowedTools: ["list_tables", "execute_query"]))

        #expect(draft.ai.alwaysAllowedTools == ["execute_query", "list_tables"])
        #expect(draft.ai.revokedTools.isEmpty)
    }

    @Test("Forget takes a tool off the list and into the revoked set, and loading again drops it")
    func forgetMovesAToolIntoTheRevokedSet() {
        let connection = DatabaseConnection(name: "Staging", aiAlwaysAllowedTools: ["list_tables", "execute_query"])
        var draft = loaded(connection)

        draft.forgetAlwaysAllowed("execute_query")

        #expect(draft.ai.alwaysAllowedTools == ["list_tables"])
        #expect(draft.ai.revokedTools == ["execute_query"])

        draft = loaded(connection)

        #expect(draft.ai.alwaysAllowedTools == ["execute_query", "list_tables"])
        #expect(draft.ai.revokedTools.isEmpty)
    }

    @Test("Shows a Redis database index saved as db4 as the number the stepper takes")
    func loadsDbPrefixedRedisIndexAsANumber() throws {
        let redis = try redisWithAdvancedIndex()
        let connection = DatabaseConnection(name: "cache", type: .redis, additionalFields: ["redisDatabase": "db4"])

        let draft = ConnectionDraft.loaded(from: connection, secrets: .none, traits: redis)

        #expect(draft.fieldValues["redisDatabase"] == "4")
    }

    @Test("Shows the Redis database a synced connection names when no index was saved")
    func loadsRedisIndexFromTheDatabaseName() throws {
        let redis = try redisWithAdvancedIndex()
        let connection = DatabaseConnection(name: "cache", database: "db7", type: .redis)

        let draft = ConnectionDraft.loaded(from: connection, secrets: .none, traits: redis)

        #expect(draft.fieldValues["redisDatabase"] == "7")
    }

    @Test("The Extensions list is its own section, not a row among the driver options")
    func extensionFieldIsNotADriverRow() throws {
        let sqlite = try sqliteWithExtensionList()
        let draft = ConnectionDraft.new(type: .sqlite, traits: sqlite)
        let advanced = try #require(ConnectionEditorEngine.layout(draft, sqlite, EditorContext()).facet(.advanced))
        let extensionRow = EditorRow.plugin(fieldID: LoadableExtensionList.fieldId)

        let section = try #require(advanced.section(containing: extensionRow))
        #expect(section.id == "extensions-\(LoadableExtensionList.fieldId)")
        #expect(section.rows == [extensionRow])
        #expect(advanced.sections.first { $0.id == "driver" }?.rows.contains(extensionRow) != true)
    }

    @Test("An invalid list blocks saving with the reason")
    func invalidListIsAValidationIssue() throws {
        let sqlite = try sqliteWithExtensionList()
        var draft = ConnectionDraft.new(type: .sqlite, traits: sqlite)
        draft.setFieldValue(
            LoadableExtensionList.encode([LoadableExtension(path: "vec0.dylib")]),
            for: LoadableExtensionList.fieldId
        )

        let issue = ConnectionEditorEngine.issues(draft, sqlite, EditorContext())
            .first { $0.row == .plugin(fieldID: LoadableExtensionList.fieldId) }

        #expect(issue?.message.contains("vec0.dylib") == true)
        #expect(issue?.facet == .advanced)
        #expect(issue?.blocksSave == true)
    }
}
