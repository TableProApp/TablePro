import Foundation
import os
import TableProConnectionLibrary
import TableProDatabase
import TableProImport
import TableProModels

@MainActor
struct IOSImportLibraryStore: ImportLibraryStore {
    private static let logger = Logger(subsystem: "com.TablePro", category: "IOSImportLibraryStore")

    let appState: AppState
    let secureStore: any SecureStore

    func snapshot() async throws -> ImportLibrarySnapshot {
        guard appState.isLibraryWritable else { throw ImportStoreError.unreadable }
        return ImportLibrarySnapshot(connections: appState.connections.map { connection in
            ImportLibrarySnapshot.Connection(
                id: connection.id,
                name: connection.name.isEmpty ? connection.host : connection.name,
                matchKey: ConnectionMatchKey(
                    host: connection.host,
                    port: connection.port,
                    database: connection.database,
                    username: connection.username,
                    redisDatabase: nil
                )
            )
        })
    }

    func addImportedProfiles(_ profiles: [PlannedCredentialProfile]) throws -> [BundleRef: UUID] {
        [:]
    }

    func ensureGroupPaths(_ paths: [[PathComponent]]) throws -> [UUID?] {
        guard appState.isLibraryWritable else { throw ImportStoreError.unreadable }
        let existing = appState.groups.map {
            PathNode(id: $0.id, name: $0.name, parentId: $0.parentId, scope: nil)
        }
        let resolved = PathTreeResolver.resolve(paths, existing: existing)

        // A group the library refuses to place hands its children and connections to its parent.
        var substitutes: [UUID: UUID?] = [:]
        func placedId(_ id: UUID?) -> UUID? {
            guard let id, let substitute = substitutes[id] else { return id }
            return substitute
        }

        for node in resolved.created {
            let parentId = placedId(node.parentId)
            let group = ConnectionGroup(
                id: node.id,
                name: node.name,
                color: node.color.map { ConnectionColor(storedValue: $0) } ?? .none,
                iconName: LibrarySymbolCatalog.normalizedName(node.iconName),
                parentId: parentId
            )
            let outcome = appState.addGroup(group)
            if outcome == .refused {
                throw ImportStoreError.unreadable
            }
            if !outcome.isSaved {
                Self.logger.error("Import could not place a group, so its connections go to its parent")
                substitutes[node.id] = parentId
            }
        }
        return resolved.leaves.map(placedId)
    }

    func ensureTags(_ tags: [PlannedTag]) throws -> [String: UUID] {
        var ids: [String: UUID] = [:]
        for tag in appState.tags {
            let key = tag.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ids[key] == nil {
                ids[key] = tag.id
            }
        }

        for planned in tags {
            let key = planned.name.lowercased()
            guard ids[key] == nil else { continue }
            let tag = ConnectionTag.presets.first { $0.name.lowercased() == key } ?? ConnectionTag(
                name: planned.name,
                color: planned.color.map { ConnectionColor(storedValue: $0, default: .gray) } ?? .gray
            )
            let outcome = appState.addTag(tag)
            if outcome == .refused {
                throw ImportStoreError.unreadable
            }
            if outcome.isSaved {
                ids[key] = tag.id
            }
        }
        return ids
    }

    func writeConnections(_ connections: [ResolvedConnection]) -> ConnectionImportWrite? {
        guard appState.isLibraryWritable else { return nil }
        var added: [UUID] = []
        var replaced: [UUID] = []
        for resolved in connections {
            let connection = DatabaseConnection(importing: resolved)
            switch resolved.planned.write {
            case .add:
                if appState.addConnection(connection) {
                    added.append(connection.id)
                }
            case .replace:
                let outcome = appState.mutateConnection(connection.id) { stored in
                    var updated = connection
                    updated.sortOrder = stored.sortOrder
                    updated.isFavorite = stored.isFavorite
                    stored = updated
                }
                if outcome.isSaved {
                    replaced.append(connection.id)
                } else {
                    Self.logger.error("Import could not replace a connection that is no longer in the library")
                }
            }
        }
        guard !added.isEmpty || !replaced.isEmpty else { return nil }
        return ConnectionImportWrite(added: added, replaced: replaced)
    }

    func existingConnectionIds() -> Set<UUID> {
        Set(appState.connections.map(\.id))
    }

    func writeCredentials(_ credentials: ExportableCredentials, connectionId: UUID) {
        let secrets: [(ConnectionSecretKind, String?)] = [
            (.password, credentials.password),
            (.sshPassword, credentials.sshPassword),
            (.keyPassphrase, credentials.keyPassphrase)
        ]
        for case let (kind, value?) in secrets {
            do {
                try secureStore.store(value, forKey: kind.account(for: connectionId))
            } catch {
                let privateDescription = String(reflecting: error)
                Self.logger.error("Restoring an imported secret failed: \(privateDescription, privacy: .private)")
            }
        }
    }
}

internal extension SSLConfiguration.SSLMode {
    // iOS has no Preferred mode, and an unknown mode must never weaken a connection to plain text.
    init(importing portable: PortableSSLMode?) {
        guard let portable else {
            self = .require
            return
        }
        switch portable {
        case .disabled: self = .disable
        case .preferred, .required: self = .require
        case .verifyCA: self = .verifyCa
        case .verifyIdentity: self = .verifyFull
        }
    }
}

private extension DatabaseConnection {
    init(importing resolved: ResolvedConnection) {
        let settings = resolved.planned.settings
        let safeModeLevel = SafeModeLevel(wireValue: settings.safeModeLevel, isReadOnly: false)
        let sslMode = settings.sslConfig.map { SSLConfiguration.SSLMode(importing: $0.portableMode) } ?? .disable
        self.init(
            id: resolved.planned.id,
            name: settings.name,
            type: DatabaseType(rawValue: settings.type),
            host: settings.host.trimmingCharacters(in: .whitespaces).isEmpty ? "localhost" : settings.host,
            port: settings.port,
            username: settings.username,
            database: settings.database,
            color: settings.color.map { ConnectionColor(storedValue: $0) } ?? .none,
            iconName: LibrarySymbolCatalog.normalizedName(settings.iconName),
            isReadOnly: safeModeLevel.blocksWrites,
            safeModeLevel: safeModeLevel,
            queryTimeoutSeconds: settings.queryTimeoutSeconds,
            additionalFields: settings.additionalFields ?? [:],
            sshEnabled: settings.sshConfig?.enabled == true,
            sshConfiguration: settings.sshConfig.flatMap { Self.sshConfiguration($0) },
            sslEnabled: sslMode != .disable,
            sslConfiguration: sslMode == .disable ? nil : settings.sslConfig.map { ssl in
                SSLConfiguration(
                    mode: sslMode,
                    caCertificatePath: Self.expandedPath(ssl.caCertificatePath),
                    clientCertificatePath: Self.expandedPath(ssl.clientCertificatePath),
                    clientKeyPath: Self.expandedPath(ssl.clientKeyPath)
                )
            },
            groupId: resolved.groupId,
            tagIds: resolved.tagIds
        )
        connectTimeoutSeconds = settings.connectTimeoutSeconds
    }

    static func sshConfiguration(_ ssh: ExportableSSHConfig) -> SSHConfiguration? {
        guard ssh.enabled else { return nil }
        return SSHConfiguration(
            host: ssh.host,
            port: ssh.port,
            username: ssh.username,
            authMethod: sshAuthMethod(ssh.authMethod),
            privateKeyPath: expandedPath(ssh.privateKeyPath),
            jumpHosts: (ssh.jumpHosts ?? []).map {
                SSHJumpHost(
                    host: $0.host,
                    port: $0.port,
                    username: $0.username,
                    macAuthMethod: SSHJumpAuthMethod(carrying: $0.authMethod),
                    macPrivateKeyPath: $0.privateKeyPath
                )
            }
        )
    }

    static func sshAuthMethod(_ raw: String) -> SSHConfiguration.SSHAuthMethod {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "privatekey", "publickey", "private key": .privateKey
        case "sshagent", "agent", "ssh agent": .sshAgent
        case "keyboardinteractive", "keyboard interactive": .keyboardInteractive
        case "none": .none
        default: .password
        }
    }

    static func expandedPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let expanded = PathPortability.expandHome(path)
        return expanded.isEmpty ? nil : expanded
    }
}
