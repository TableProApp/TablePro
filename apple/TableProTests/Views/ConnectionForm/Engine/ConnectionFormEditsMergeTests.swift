//
//  ConnectionFormEditsMergeTests.swift
//  TableProTests
//

import Foundation
import TableProAutocomplete
import TableProPluginKit
import TableProSSHConfig
import Testing

@testable import TablePro

// Save applies the form onto a fresh read: a value the form did not change keeps what another writer stored.
@MainActor
struct ConnectionFormEditsMergeTests {
    private struct Property {
        let change: (inout DatabaseConnection) -> Void
        let read: (DatabaseConnection) -> String
    }

    private struct StoredKey {
        let change: (inout DatabaseConnection) -> Void
        let remove: (inout DatabaseConnection) -> Void
        let read: (DatabaseConnection) -> String
    }

    private static let carriedOver: Set<String> = [
        "id", "aiAlwaysAllowedTools", "sortOrder", "isSample", "isFavorite", "passwordSource", "sshRoute", "origin"
    ]

    private static let pluginKey = "pluginOption"

    private static func describe<Value>(_ value: Value) -> String { String(describing: value) }

    // One entry per property the form writes; the Mirror check below fails when DatabaseConnection gains one.
    private static let properties: [String: Property] = [
        "name": Property(change: { $0.name = "Concurrent" }, read: { describe($0.name) }),
        "host": Property(change: { $0.host = "other.example.com" }, read: { describe($0.host) }),
        "port": Property(change: { $0.port = 6_000 }, read: { describe($0.port) }),
        "database": Property(change: { $0.database = "other" }, read: { describe($0.database) }),
        "username": Property(change: { $0.username = "other" }, read: { describe($0.username) }),
        "type": Property(change: { $0.type = .mariadb }, read: { describe($0.type) }),
        "sshConfig": Property(change: { $0.sshConfig.host = "changed" }, read: { describe($0.sshConfig) }),
        "sslConfig": Property(change: { $0.sslConfig.mode = .required }, read: { describe($0.sslConfig) }),
        "color": Property(change: { $0.color = .red }, read: { describe($0.color) }),
        "iconName": Property(change: { $0.iconName = "star" }, read: { describe($0.iconName) }),
        "tagIds": Property(change: { $0.tagIds = [UUID()] }, read: { describe($0.tagIds) }),
        "groupId": Property(change: { $0.groupId = UUID() }, read: { describe($0.groupId) }),
        "sshProfileId": Property(change: { $0.sshProfileId = UUID() }, read: { describe($0.sshProfileId) }),
        "sshTunnelMode": Property(
            change: { $0.sshTunnelMode = .inline(SSHConfiguration(enabled: true, host: "bastion")) },
            read: { describe($0.sshTunnelMode) }
        ),
        "credentialMode": Property(change: { $0.credentialMode = .profile(id: UUID()) }, read: { describe($0.credentialMode) }),
        "cloudflareTunnelMode": Property(
            change: {
                $0.cloudflareTunnelMode = .inline(CloudflareConfiguration(
                    accessHostname: "db.example.com", localPort: nil, authMethod: .browserSSO, exposeToLAN: false, binaryPath: ""
                ))
            },
            read: { describe($0.cloudflareTunnelMode) }
        ),
        "cloudSQLProxyMode": Property(
            change: {
                $0.cloudSQLProxyMode = .inline(CloudSQLProxyConfiguration(
                    instanceConnectionName: "p:r:i", authMode: .applicationDefault, useIAMAuth: false,
                    usePrivateIP: false, localPort: nil, binaryPath: ""
                ))
            },
            read: { describe($0.cloudSQLProxyMode) }
        ),
        "socksProxyMode": Property(
            change: { $0.socksProxyMode = .inline(SOCKSProxyConfiguration(host: "proxy", port: 1_080, username: "")) },
            read: { describe($0.socksProxyMode) }
        ),
        "tunnelCommandMode": Property(
            change: { $0.tunnelCommandMode = .inline(TunnelCommandConfiguration()) },
            read: { describe($0.tunnelCommandMode) }
        ),
        "preferredSafeModeLevel": Property(change: { $0.preferredSafeModeLevel = .readOnly }, read: { describe($0.preferredSafeModeLevel) }),
        "aiPolicy": Property(change: { $0.aiPolicy = .never }, read: { describe($0.aiPolicy) }),
        "aiRules": Property(change: { $0.aiRules = "Prefer views" }, read: { describe($0.aiRules) }),
        "externalAccess": Property(change: { $0.externalAccess = .blocked }, read: { describe($0.externalAccess) }),
        "redisDatabase": Property(change: { $0.redisDatabase = 4 }, read: { describe($0.redisDatabase) }),
        "startupCommands": Property(change: { $0.startupCommands = "SET x = 1" }, read: { describe($0.startupCommands) }),
        "localOnly": Property(change: { $0.localOnly = true }, read: { describe($0.localOnly) })
    ]

    // The typed properties that sit over an additionalFields key, plus a plugin field.
    private static let storedKeys: [String: StoredKey] = [
        "connectTimeoutSeconds": StoredKey(
            change: { $0.connectTimeoutSeconds = 45 },
            remove: { $0.connectTimeoutSeconds = nil },
            read: { describe($0.connectTimeoutSeconds) }
        ),
        "queryTimeoutSeconds": StoredKey(
            change: { $0.queryTimeoutSeconds = 90 },
            remove: { $0.queryTimeoutSeconds = nil },
            read: { describe($0.queryTimeoutSeconds) }
        ),
        "binaryInlineLimitKilobytes": StoredKey(
            change: { $0.binaryInlineLimitKilobytes = 512 },
            remove: { $0.binaryInlineLimitKilobytes = nil },
            read: { describe($0.binaryInlineLimitKilobytes) }
        ),
        "completionIdentifierCase": StoredKey(
            change: { $0.completionIdentifierCase = .lower },
            remove: { $0.completionIdentifierCase = .default },
            read: { describe($0.completionIdentifierCase) }
        ),
        "commitMode": StoredKey(
            change: { $0.commitMode = .automatic },
            remove: { $0.commitMode = .automatic },
            read: { describe($0.commitMode) }
        ),
        "maskingRules": StoredKey(
            change: { $0.maskingRules = [MaskingRule(pattern: "*.ssn")] },
            remove: { $0.maskingRules = [] },
            read: { describe($0.maskingRules.map(\.pattern)) }
        ),
        pluginKey: StoredKey(
            change: { $0.additionalFields[pluginKey] = "changed" },
            remove: { $0.additionalFields[pluginKey] = nil },
            read: { describe($0.additionalFields[pluginKey]) }
        )
    ]

    private static func base() -> DatabaseConnection {
        var connection = DatabaseConnection(
            id: UUID(),
            name: "Shop",
            host: "db.example.com",
            port: 3_306,
            database: "shop",
            username: "app",
            type: .mysql
        )
        connection.connectTimeoutSeconds = 20
        connection.queryTimeoutSeconds = 30
        connection.binaryInlineLimitKilobytes = 128
        connection.completionIdentifierCase = .upper
        connection.commitMode = .manual
        connection.maskingRules = [MaskingRule(pattern: "*.email")]
        connection.additionalFields[pluginKey] = "original"
        return connection
    }

    private static func edits(_ connection: DatabaseConnection) -> ConnectionFormEdits {
        ConnectionFormEdits(
            name: connection.name,
            host: connection.host,
            port: connection.port,
            database: connection.database,
            username: connection.username,
            type: connection.type,
            sshConfig: connection.sshConfig,
            sslConfig: connection.sslConfig,
            color: connection.color,
            iconName: connection.iconName,
            tagIds: connection.tagIds,
            groupId: connection.groupId,
            sshProfileId: connection.sshProfileId,
            sshTunnelMode: connection.sshTunnelMode,
            credentialMode: connection.credentialMode,
            cloudflareTunnelMode: connection.cloudflareTunnelMode,
            cloudSQLProxyMode: connection.cloudSQLProxyMode,
            socksProxyMode: connection.socksProxyMode,
            tunnelCommandMode: connection.tunnelCommandMode,
            safeModeLevel: connection.preferredSafeModeLevel,
            aiPolicy: connection.aiPolicy,
            aiRules: connection.aiRules,
            externalAccess: connection.externalAccess,
            connectTimeoutSeconds: connection.connectTimeoutSeconds,
            queryTimeoutSeconds: connection.queryTimeoutSeconds,
            binaryInlineLimitKilobytes: connection.binaryInlineLimitKilobytes,
            completionIdentifierCase: connection.completionIdentifierCase,
            commitMode: connection.commitMode,
            redisDatabase: connection.redisDatabase,
            startupCommands: connection.startupCommands,
            localOnly: connection.localOnly,
            additionalFields: connection.additionalFields,
            ownedAdditionalFieldIDs: ConnectionFormEdits.appManagedAdditionalFieldIDs.union([pluginKey]),
            maskingRules: connection.maskingRules
        )
    }

    @Test("The table covers every property the form writes")
    func tableCoversEveryWrittenProperty() {
        let stored = Set(Mirror(reflecting: Self.base()).children.compactMap(\.label))
        let written = stored.subtracting(Self.carriedOver).subtracting(["additionalFields"])
        #expect(Set(Self.properties.keys) == written)
    }

    @Test("A property another writer changed, and the form did not, keeps the other writer's value")
    func concurrentChangeIsKept() {
        for (name, property) in Self.properties {
            let base = Self.base()
            var fresh = base
            property.change(&fresh)
            let result = Self.edits(base).applied(to: fresh, since: Self.edits(base))
            #expect(property.read(result) == property.read(fresh), "\(name)")
        }
        for (name, key) in Self.storedKeys {
            let base = Self.base()
            var fresh = base
            key.change(&fresh)
            let result = Self.edits(base).applied(to: fresh, since: Self.edits(base))
            #expect(key.read(result) == key.read(fresh), "\(name)")
        }
    }

    @Test("A property the form changed overwrites the stored one")
    func draftChangeWins() {
        for (name, property) in Self.properties {
            let base = Self.base()
            var edited = base
            property.change(&edited)
            let result = Self.edits(edited).applied(to: base, since: Self.edits(base))
            #expect(property.read(result) == property.read(edited), "\(name)")
        }
        for (name, key) in Self.storedKeys {
            let base = Self.base()
            var edited = base
            key.change(&edited)
            let result = Self.edits(edited).applied(to: base, since: Self.edits(base))
            #expect(key.read(result) == key.read(edited), "\(name)")
        }
    }

    @Test("A key the form cleared is removed")
    func draftDeletionRemovesTheKey() {
        for (name, key) in Self.storedKeys {
            let base = Self.base()
            var edited = base
            key.remove(&edited)
            let result = Self.edits(edited).applied(to: base, since: Self.edits(base))
            #expect(key.read(result) == key.read(edited), "\(name)")
        }
    }

    @Test("A key another writer removed, and the form did not touch, stays removed")
    func concurrentDeletionIsNotResurrected() {
        for (name, key) in Self.storedKeys {
            let base = Self.base()
            var fresh = base
            key.remove(&fresh)
            let result = Self.edits(base).applied(to: fresh, since: Self.edits(base))
            #expect(key.read(result) == key.read(fresh), "\(name)")
        }
    }

    @Test("Without a baseline the merge is the plain apply")
    func noBaselineIsPlainApply() {
        let base = Self.base()
        var edited = base
        edited.name = "Renamed"
        #expect(Self.edits(edited).applied(to: base, since: nil) == Self.edits(edited).applied(to: base))
    }
}
