//
//  MacImportLibraryStore.swift
//  TablePro
//

import Foundation
import os
import TableProImport

@MainActor
internal struct MacImportLibraryStore: ImportLibraryStore {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MacImportLibraryStore")

    private let connections: ConnectionStorage
    private let groups: GroupStorage
    private let tags: TagStorage
    private let profiles: CredentialProfileStorage
    private let sshProfiles: SSHProfileStorage
    private let favorites: SQLFavoriteManager

    init(
        connections: ConnectionStorage = .shared,
        groups: GroupStorage = .shared,
        tags: TagStorage = .shared,
        profiles: CredentialProfileStorage = .shared,
        sshProfiles: SSHProfileStorage = .shared,
        favorites: SQLFavoriteManager = .shared
    ) {
        self.connections = connections
        self.groups = groups
        self.tags = tags
        self.profiles = profiles
        self.sshProfiles = sshProfiles
        self.favorites = favorites
    }

    func snapshot() async throws -> ImportLibrarySnapshot {
        try await readLibrary().snapshot
    }

    /// The library plus `environment` with the rules this Mac can honour right now: unreadable saved
    /// queries or credential profiles turn their import off instead of refusing the whole file.
    func analysisInputs(
        environment: ImportEnvironment
    ) async throws -> (library: ImportLibrarySnapshot, environment: ImportEnvironment) {
        let read = try await readLibrary()
        var adjusted = environment
        if !read.savedQueriesReadable {
            adjusted.rules.supportsSavedQueries = false
        }
        _ = profiles.loadProfiles()
        if profiles.lastLoadFailed {
            adjusted.rules.supportsCredentialProfiles = false
        }
        return (read.snapshot, adjusted)
    }

    func addImportedProfiles(_ planned: [PlannedCredentialProfile]) throws -> [BundleRef: UUID] {
        guard let created = profiles.addImportedProfiles(planned) else {
            Self.logger.error("Credential profiles were not imported: the profile store refused the write")
            throw ImportStoreError.unreadable
        }
        return created
    }

    func ensureGroupPaths(_ paths: [[PathComponent]]) throws -> [UUID?] {
        try groups.ensureGroupPaths(paths)
    }

    func ensureTags(_ planned: [PlannedTag]) throws -> [String: UUID] {
        try tags.ensureTags(planned)
    }

    func writeConnections(_ resolved: [ResolvedConnection]) -> ConnectionImportWrite? {
        var adding: [DatabaseConnection] = []
        var replacing: [DatabaseConnection] = []
        for connection in resolved {
            let built = DatabaseConnection(
                importing: connection.planned.settings,
                id: connection.planned.id,
                groupId: connection.groupId,
                tagIds: connection.tagIds,
                credentialProfileId: connection.credentialProfileId,
                resolvesSSHProfile: { sshProfiles.profile(for: $0) != nil }
            )
            switch connection.planned.write {
            case .add: adding.append(built)
            case .replace: replacing.append(built)
            }
        }
        guard let write = connections.applyImport(adding: adding, replacing: replacing) else {
            Self.logger.error("Imported connections were not saved")
            return nil
        }
        Self.logger.info(
            "Imported connections: \(write.added.count, privacy: .public) added, \(write.replaced.count, privacy: .public) replaced"
        )
        return write
    }

    func existingConnectionIds() -> Set<UUID> {
        Set(connections.loadConnections().map(\.id))
    }

    func writeCredentials(_ credentials: ExportableCredentials, connectionId: UUID) {
        if let password = credentials.password {
            connections.savePassword(password, for: connectionId)
        }
        if let sshPassword = credentials.sshPassword {
            connections.saveSSHPassword(sshPassword, for: connectionId)
        }
        if let keyPassphrase = credentials.keyPassphrase {
            connections.saveKeyPassphrase(keyPassphrase, for: connectionId)
        }
        if let sslClientKeyPassphrase = credentials.sslClientKeyPassphrase {
            connections.saveSSLClientKeyPassphrase(sslClientKeyPassphrase, for: connectionId)
        }
        if let totpSecret = credentials.totpSecret {
            connections.saveTOTPSecret(totpSecret, for: connectionId)
        }
        for (fieldId, value) in credentials.pluginSecureFields ?? [:] {
            connections.savePluginSecureField(value, fieldId: fieldId, for: connectionId)
        }
    }

    private func readLibrary() async throws -> (snapshot: ImportLibrarySnapshot, savedQueriesReadable: Bool) {
        let ledger = await favorites.ledgerEntries()
        if ledger == nil {
            Self.logger.error("Saved queries could not be read, so this import leaves them out")
        }

        let stored = connections.loadConnections()
        guard !connections.isLibraryUnreadable else {
            Self.logger.error("Import refused: the saved connections could not be read")
            throw ImportStoreError.unreadable
        }
        _ = groups.loadGroups()
        guard !groups.storeIsUnreadable else {
            Self.logger.error("Import refused: the saved groups could not be read")
            throw ImportStoreError.unreadable
        }
        _ = tags.loadTags()
        guard !tags.storeIsUnreadable else {
            Self.logger.error("Import refused: the saved tags could not be read")
            throw ImportStoreError.unreadable
        }

        let snapshot = ImportLibrarySnapshot(
            connections: stored.map { connection in
                ImportLibrarySnapshot.Connection(
                    id: connection.id,
                    name: connection.name,
                    matchKey: ConnectionMatchKey(
                        host: connection.host,
                        port: connection.port,
                        database: connection.database,
                        username: connection.username,
                        redisDatabase: connection.redisDatabase
                    )
                )
            },
            savedQueries: ledger ?? []
        )
        return (snapshot, ledger != nil)
    }
}

@MainActor
internal enum MacImportEnvironment {
    static func make(
        pluginManager: PluginManager = .shared,
        registry: PluginMetadataRegistry = .shared
    ) -> ImportEnvironment {
        let registeredTypeIds = Set(registry.allRegisteredTypeIds())
        var missingDriverNames: [String: String] = [:]
        for typeId in registeredTypeIds {
            let type = DatabaseType(rawValue: typeId)
            guard case .notInstalled = pluginManager.driverUnavailability(for: type) else { continue }
            missingDriverNames[typeId] = PluginManager.registryDisplayName(of: type)
        }
        return ImportEnvironment(
            rules: ImportRules(
                maximumGroupDepth: ConnectionGroup.maxNestingDepth,
                supportsSavedQueries: true,
                supportsCredentialProfiles: true
            ),
            registeredTypeIds: registeredTypeIds,
            missingDriverNames: missingDriverNames,
            fileExists: { path in FileManager.default.fileExists(atPath: path) }
        )
    }
}
