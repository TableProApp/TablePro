//
//  ConnectionFormEditsCoverageTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// Guards the contract behind `ConnectionFormEdits`: every stored property of
/// `DatabaseConnection` is either written by the form or carried over untouched.
/// A property that is neither is one the connection form silently resets on save,
/// which is how the favorite mark, the sort order and the AI tool grants were lost.
@Suite("Connection form edits coverage")
struct ConnectionFormEditsCoverageTests {
    private static let writtenByForm: Set<String> = [
        "name",
        "host",
        "port",
        "database",
        "username",
        "type",
        "sshConfig",
        "sslConfig",
        "color",
        "tagIds",
        "groupId",
        "sshProfileId",
        "sshTunnelMode",
        "cloudflareTunnelMode",
        "cloudSQLProxyMode",
        "socksProxyMode",
        "safeModeLevel",
        "aiPolicy",
        "aiRules",
        "externalAccess",
        "redisDatabase",
        "startupCommands",
        "localOnly",
        "additionalFields"
    ]

    private static let carriedOver: Set<String> = [
        "id",
        "aiAlwaysAllowedTools",
        "sortOrder",
        "isSample",
        "isFavorite",
        "passwordSource"
    ]

    private static func storedPropertyNames() -> Set<String> {
        let connection = DatabaseConnection(id: UUID(), name: "")
        return Set(Mirror(reflecting: connection).children.compactMap(\.label))
    }

    @Test("Every stored property is classified as written or carried over")
    func everyPropertyIsClassified() {
        let unclassified = Self.storedPropertyNames()
            .subtracting(Self.writtenByForm)
            .subtracting(Self.carriedOver)

        #expect(
            unclassified.isEmpty,
            """
            DatabaseConnection gained \(unclassified.sorted().joined(separator: ", ")).
            Add each name to writtenByForm and to ConnectionFormEdits, or to carriedOver.
            An unclassified property is reset to its default every time a connection is edited.
            """
        )
    }

    @Test("No classified property has disappeared from the model")
    func noClassifiedPropertyIsStale() {
        let stale = Self.writtenByForm
            .union(Self.carriedOver)
            .subtracting(Self.storedPropertyNames())

        #expect(
            stale.isEmpty,
            "These names are classified but no longer exist: \(stale.sorted().joined(separator: ", "))."
        )
    }

    @Test("A property is not both written and carried over")
    func classificationsDoNotOverlap() {
        #expect(Self.writtenByForm.isDisjoint(with: Self.carriedOver))
    }

    @Test("Applying edits changes only the properties classified as written")
    func onlyWrittenPropertiesChange() {
        var original = DatabaseConnection(
            id: UUID(),
            name: "Original",
            host: "127.0.0.1",
            port: 5_432,
            database: "original_db",
            username: "original_user",
            type: .mysql
        )
        original.sortOrder = 7
        original.isFavorite = true
        original.isSample = true
        original.aiAlwaysAllowedTools = ["run_query"]
        original.passwordSource = .env(variable: "PGPASSWORD")

        let result = ConnectionFormEdits(
            name: original.name,
            host: original.host,
            port: original.port,
            database: original.database,
            username: original.username,
            type: original.type,
            sshConfig: original.sshConfig,
            sslConfig: original.sslConfig,
            color: original.color,
            tagIds: original.tagIds,
            groupId: original.groupId,
            sshProfileId: original.sshProfileId,
            sshTunnelMode: original.sshTunnelMode,
            cloudflareTunnelMode: original.cloudflareTunnelMode,
            cloudSQLProxyMode: original.cloudSQLProxyMode,
            socksProxyMode: original.socksProxyMode,
            safeModeLevel: original.safeModeLevel,
            aiPolicy: original.aiPolicy,
            aiRules: original.aiRules,
            externalAccess: original.externalAccess,
            redisDatabase: original.redisDatabase,
            startupCommands: original.startupCommands,
            localOnly: original.localOnly,
            additionalFields: original.additionalFields,
            ownedAdditionalFieldIDs: []
        ).applied(to: original)

        #expect(result == original)
    }
}
