//
//  ConnectionBundleExporter.swift
//  TablePro
//

import Foundation
import os
import TableProImport

internal enum ConnectionBundleExportError: LocalizedError, Equatable {
    case savedQueriesUnreadable

    var errorDescription: String? {
        switch self {
        case .savedQueriesUnreadable:
            return String(localized: "The saved queries could not be read. Nothing was exported.")
        }
    }
}

@MainActor
internal struct ConnectionBundleExporter {
    private typealias SavedQueryLibrary = (favorites: [SQLFavorite], folders: [SQLFavoriteFolder])

    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionBundleExporter")

    nonisolated static var bundledAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private let connections: ConnectionStorage
    private let groups: GroupStorage
    private let tags: TagStorage
    private let profiles: CredentialProfileStorage
    private let sshProfiles: SSHProfileStorage
    private let favorites: SQLFavoriteManager
    private let registry: PluginMetadataRegistry
    private let appVersion: String

    init(
        connections: ConnectionStorage = .shared,
        groups: GroupStorage = .shared,
        tags: TagStorage = .shared,
        profiles: CredentialProfileStorage = .shared,
        sshProfiles: SSHProfileStorage = .shared,
        favorites: SQLFavoriteManager = .shared,
        registry: PluginMetadataRegistry = .shared,
        appVersion: String = ConnectionBundleExporter.bundledAppVersion
    ) {
        self.connections = connections
        self.groups = groups
        self.tags = tags
        self.profiles = profiles
        self.sshProfiles = sshProfiles
        self.favorites = favorites
        self.registry = registry
        self.appVersion = appVersion
    }

    func portableSettings(for connection: DatabaseConnection) -> ExportableConnection {
        var settings = ExportableConnection(
            name: connection.name,
            host: connection.host,
            port: connection.port,
            database: connection.database,
            username: connection.username,
            type: connection.type.rawValue
        )
        settings.sshConfig = ExportableSSHConfig(portable: sshConfiguration(for: connection))
        settings.sslConfig = ExportableSSLConfig(portable: connection.sslConfig)
        settings.color = connection.color.isDefault ? nil : connection.color.rawValue
        settings.iconName = connection.iconName
        settings.sshProfileId = connection.sshProfileId?.uuidString
        settings.safeModeLevel = connection.preferredSafeModeLevel == .silent ? nil : connection.preferredSafeModeLevel.rawValue
        settings.aiPolicy = connection.aiPolicy?.rawValue
        settings.connectTimeoutSeconds = DatabaseConnection.portableConnectTimeout(connection.connectTimeoutSeconds)
        settings.queryTimeoutSeconds = DatabaseConnection.portableQueryTimeout(connection.queryTimeoutSeconds)
        settings.additionalFields = shareableAdditionalFields(for: connection)
        settings.redisDatabase = connection.redisDatabase
        settings.startupCommands = connection.startupCommands
        settings.localOnly = connection.localOnly ? true : nil
        settings.tunnelCommand = connection.resolvedTunnelCommandConfig.map { ExportableTunnelCommand($0) }
        return settings
    }

    func groupPath(for connection: DatabaseConnection) -> [String] {
        let groupsById = Dictionary(groups.loadGroups().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var path: [String] = []
        var visited: Set<UUID> = []
        var cursor = connection.groupId
        while let id = cursor, visited.insert(id).inserted, let group = groupsById[id] {
            path.insert(group.name, at: 0)
            cursor = group.parentId
        }
        return path
    }

    func tagNames(for connection: DatabaseConnection) -> [String] {
        tags.tags(for: connection.tagIds).map(\.name)
    }

    func connectionsOnlyBundle(for connections: [DatabaseConnection]) throws -> ConnectionBundle {
        try BundleExportAssembler.assemble(
            exportInput(for: connections, includesCredentials: false, library: nil),
            options: .connectionsOnly,
            appVersion: appVersion
        )
    }

    /// Nil when the saved queries cannot be read, which is not the same as having none.
    func savedQueryCounts(for connections: [DatabaseConnection]) async -> SavedQueryCounts? {
        guard let library = await favorites.exportSnapshot() else {
            Self.logger.error("Saved queries could not be read for the export options")
            return nil
        }
        return BundleExportAssembler.savedQueryCounts(
            exportInput(for: connections, includesCredentials: false, library: library)
        )
    }

    func fileData(
        for connections: [DatabaseConnection],
        options: BundleExportOptions,
        passphrase: String?
    ) async throws -> Data {
        if options.includesCredentials, passphrase == nil {
            throw ConnectionBundleError.credentialsRequireEncryption
        }
        var library: SavedQueryLibrary?
        if options.includesSavedQueries {
            guard let snapshot = await favorites.exportSnapshot() else {
                Self.logger.error("Export refused: saved queries could not be read")
                throw ConnectionBundleExportError.savedQueriesUnreadable
            }
            library = snapshot
        }
        let input = exportInput(for: connections, includesCredentials: options.includesCredentials, library: library)
        let bundle = try BundleExportAssembler.assemble(input, options: options, appVersion: appVersion)
        let data = try await Self.encode(bundle, passphrase: passphrase)
        Self.logger.info(
            "Exported \(bundle.connections.count, privacy: .public) connections, \(bundle.savedQueries.count, privacy: .public) saved queries"
        )
        return data
    }

    static func portablePasswordMode(_ mode: CredentialPasswordMode) -> BundlePasswordMode {
        switch mode {
        case .stored: .stored
        case .pgpass: .pgpass
        // A command or file source would run on the importing Mac, so it travels as a prompt.
        case .prompt, .source: .prompt
        }
    }

    @concurrent
    nonisolated private static func encode(_ bundle: ConnectionBundle, passphrase: String?) async throws -> Data {
        guard let passphrase else { return try ConnectionBundleCodec.encode(bundle) }
        return try await ConnectionBundleCodec.encode(bundle, passphrase: passphrase)
    }

    private func sshConfiguration(for connection: DatabaseConnection) -> SSHConfiguration {
        guard let profileId = connection.sshProfileId, let profile = sshProfiles.profile(for: profileId) else {
            return connection.sshConfig
        }
        return profile.toSSHConfiguration()
    }

    private func shareableAdditionalFields(for connection: DatabaseConnection) -> [String: String]? {
        // Without metadata the secure fields are unknown, so nothing is shared.
        guard registry.snapshot(for: connection.type) != nil else { return nil }
        var fields = connection.additionalFields
        fields.removeValue(forKey: DatabaseConnection.connectTimeoutSecondsKey)
        fields.removeValue(forKey: DatabaseConnection.queryTimeoutSecondsKey)
        return ExportableConnection.shareableAdditionalFields(
            fields,
            excluding: Set(PluginManager.shared.secureConnectionFieldIds(for: connection.type))
        )
    }

    private func credentials(for connection: DatabaseConnection) -> ExportableCredentials? {
        var pluginSecureFields: [String: String] = [:]
        if registry.snapshot(for: connection.type) != nil {
            for fieldId in PluginManager.shared.secureConnectionFieldIds(for: connection.type) {
                if let value = connections.loadPluginSecureField(fieldId: fieldId, for: connection.id) {
                    pluginSecureFields[fieldId] = value
                }
            }
        }
        let credentials = ExportableCredentials(
            password: connections.loadPassword(for: connection.id),
            sshPassword: connections.loadSSHPassword(for: connection.id),
            keyPassphrase: connections.loadKeyPassphrase(for: connection.id),
            sslClientKeyPassphrase: connections.loadSSLClientKeyPassphrase(for: connection.id),
            totpSecret: connections.loadTOTPSecret(for: connection.id),
            pluginSecureFields: pluginSecureFields.isEmpty ? nil : pluginSecureFields
        )
        let carriesSecret = credentials.password != nil || credentials.sshPassword != nil
            || credentials.keyPassphrase != nil || credentials.sslClientKeyPassphrase != nil
            || credentials.totpSecret != nil || credentials.pluginSecureFields != nil
        return carriesSecret ? credentials : nil
    }

    private func exportInput(
        for exported: [DatabaseConnection],
        includesCredentials: Bool,
        library: SavedQueryLibrary?
    ) -> BundleExportInput {
        BundleExportInput(
            connections: exported.map { connection in
                BundleExportInput.Connection(
                    id: connection.id,
                    settings: portableSettings(for: connection),
                    groupId: connection.groupId,
                    tagIds: connection.tagIds,
                    credentialProfileId: connection.credentialMode.profileId,
                    credentials: includesCredentials ? credentials(for: connection) : nil
                )
            },
            groups: groups.loadGroups().map { group in
                BundleExportInput.Group(
                    id: group.id,
                    name: group.name,
                    color: group.color.isDefault ? nil : group.color.rawValue,
                    iconName: group.iconName,
                    parentId: group.parentId
                )
            },
            tags: tags.loadTags().map { tag in
                BundleExportInput.Tag(id: tag.id, name: tag.name, color: tag.color.isDefault ? nil : tag.color.rawValue)
            },
            credentialProfiles: profiles.loadProfiles().map { profile in
                BundleExportInput.CredentialProfile(
                    id: profile.id,
                    name: profile.name,
                    username: profile.username,
                    passwordMode: Self.portablePasswordMode(profile.passwordMode),
                    secureFieldIds: profile.secureFieldIds
                )
            },
            queryFolders: (library?.folders ?? []).map { folder in
                BundleExportInput.QueryFolder(
                    id: folder.id,
                    name: folder.name,
                    parentId: folder.parentId,
                    connectionId: folder.connectionId
                )
            },
            savedQueries: (library?.favorites ?? []).map { favorite in
                BundleExportInput.SavedQuery(
                    id: favorite.id,
                    name: favorite.name,
                    sql: favorite.query,
                    keyword: favorite.keyword,
                    folderId: favorite.folderId,
                    connectionId: favorite.connectionId
                )
            }
        )
    }
}
