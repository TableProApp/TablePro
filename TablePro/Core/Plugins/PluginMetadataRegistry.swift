//
//  PluginMetadataRegistry.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

struct PluginMetadataSnapshot: Sendable {
    let displayName: String
    let iconName: String
    let defaultPort: Int
    let requiresAuthentication: Bool
    let supportsForeignKeys: Bool
    let supportsSchemaEditing: Bool
    let isDownloadable: Bool
    let primaryUrlScheme: String
    let parameterStyle: ParameterStyle
    let navigationModel: NavigationModel
    let explainVariants: [ExplainVariant]
    let pathFieldRole: PathFieldRole
    let supportsHealthMonitor: Bool
    let urlSchemes: [String]
    let postConnectActions: [PostConnectAction]
    let brandColorHex: String
    let queryLanguageName: String
    let editorLanguage: EditorLanguage
    let connectionMode: ConnectionMode
    let supportsDatabaseSwitching: Bool
    let supportsColumnReorder: Bool

    let capabilities: CapabilityFlags
    let schema: SchemaInfo
    var editor: EditorConfig
    let connection: ConnectionConfig

    struct CapabilityFlags: Sendable {
        let supportsSchemaSwitching: Bool
        let supportsImport: Bool
        let supportsExport: Bool
        let supportsSSH: Bool
        let supportsSSL: Bool
        let supportsCascadeDrop: Bool
        let supportsForeignKeyDisable: Bool
        let supportsReadOnlyMode: Bool
        let supportsQueryProgress: Bool
        let requiresReconnectForDatabaseSwitch: Bool
        let supportsDropDatabase: Bool
        var supportsRenameTable: Bool = false
        var supportsRenameView: Bool = false
        var supportsRenameDatabase: Bool = false
        var supportsRenameSchema: Bool = false
        // `var` with defaults so existing call sites compile without passing these fields
        var supportsDropSchema: Bool = false
        var supportsAddColumn: Bool = true
        var supportsModifyColumn: Bool = true
        var supportsDropColumn: Bool = true
        var supportsRenameColumn: Bool = false
        var supportsAddIndex: Bool = true
        var supportsDropIndex: Bool = true
        var supportsModifyPrimaryKey: Bool = true
        var supportsTriggers: Bool = false
        var supportsTriggerEditing: Bool = false
        var supportsCheckConstraints: Bool = false
        var supportsCheckConstraintEditing: Bool = false
        var supportsGeneratedColumns: Bool = false
        var supportsRoutines: Bool = false
        var supportsDatabaseTriggerBrowse: Bool = false
        var defaultSSLMode: SSLMode = .disabled
        var supportsOpportunisticTLS: Bool = true
        var supportsCloudflareTunnel: Bool = true
        var supportsClientKeyPassphrase: Bool = false
        var supportsConnectionPooling: Bool = true
        var authenticationIsDatabaseScoped: Bool = false

        /// Which connection field carries the path of the local database file this driver opens,
        /// for the types that open one. Nil for every driver that reaches its database over the
        /// network, which is what makes it the test for "can this connection name a remote file".
        var localFilePathField: LocalFilePathField?

        var supportsSOCKSProxy: Bool { supportsSSH }

        /// Whether this type may point at a file on an SSH server instead of a local one.
        ///
        /// Deliberately not derived from `localFilePathField`. Beancount opens a local file and must
        /// still be excluded: a ledger is a graph of files reached through `include`, so one file
        /// out of it either fails to load or presents incomplete accounts, which is worse.
        var supportsRemoteDatabaseFile: Bool = false

        static let defaults = CapabilityFlags(
            supportsSchemaSwitching: false,
            supportsImport: true,
            supportsExport: true,
            supportsSSH: true,
            supportsSSL: true,
            supportsCascadeDrop: false,
            supportsForeignKeyDisable: true,
            supportsReadOnlyMode: true,
            supportsQueryProgress: false,
            requiresReconnectForDatabaseSwitch: false,
            supportsDropDatabase: false,
            supportsAddColumn: true,
            supportsModifyColumn: true,
            supportsDropColumn: true,
            supportsRenameColumn: false,
            supportsAddIndex: true,
            supportsDropIndex: true,
            supportsModifyPrimaryKey: true,
            defaultSSLMode: .disabled,
            supportsOpportunisticTLS: true,
            supportsCloudflareTunnel: true
        )
    }

    struct SchemaInfo: Sendable {
        let defaultSchemaName: String
        let defaultGroupName: String
        let tableEntityName: String
        let containerEntityName: String
        let schemaEntityName: String
        let defaultPrimaryKeyColumn: String?
        let immutableColumns: [String]
        let systemDatabaseNames: [String]
        let systemSchemaNames: [String]
        let fileExtensions: [String]
        /// Curated in the app rather than declared by the plugin: claiming a format from the
        /// system also needs a `CFBundleDocumentTypes` entry only the app bundle can make.
        let fileSignatures: [DatabaseFileSignature]
        let databaseGroupingStrategy: GroupingStrategy
        let structureColumnFields: [StructureColumnField]

        init(
            defaultSchemaName: String,
            defaultGroupName: String,
            tableEntityName: String,
            containerEntityName: String,
            schemaEntityName: String = "Schema",
            defaultPrimaryKeyColumn: String?,
            immutableColumns: [String],
            systemDatabaseNames: [String],
            systemSchemaNames: [String],
            fileExtensions: [String],
            fileSignatures: [DatabaseFileSignature] = [],
            databaseGroupingStrategy: GroupingStrategy,
            structureColumnFields: [StructureColumnField]
        ) {
            self.defaultSchemaName = defaultSchemaName
            self.defaultGroupName = defaultGroupName
            self.tableEntityName = tableEntityName
            self.containerEntityName = containerEntityName
            self.schemaEntityName = schemaEntityName
            self.defaultPrimaryKeyColumn = defaultPrimaryKeyColumn
            self.immutableColumns = immutableColumns
            self.systemDatabaseNames = systemDatabaseNames
            self.systemSchemaNames = systemSchemaNames
            self.fileExtensions = fileExtensions
            self.fileSignatures = fileSignatures
            self.databaseGroupingStrategy = databaseGroupingStrategy
            self.structureColumnFields = structureColumnFields
        }

        static let defaults = SchemaInfo(
            defaultSchemaName: "public",
            defaultGroupName: "main",
            tableEntityName: "Tables",
            containerEntityName: "Database",
            defaultPrimaryKeyColumn: nil,
            immutableColumns: [],
            systemDatabaseNames: [],
            systemSchemaNames: [],
            fileExtensions: [],
            databaseGroupingStrategy: .byDatabase,
            structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
        )
    }

    struct EditorConfig: Sendable {
        var sqlDialect: SQLDialectDescriptor?
        let statementCompletions: [CompletionEntry]
        let columnTypesByCategory: [String: [String]]

        static let defaults = EditorConfig(
            sqlDialect: nil,
            statementCompletions: [],
            columnTypesByCategory: [
                "Integer": ["INTEGER", "INT", "SMALLINT", "BIGINT", "TINYINT"],
                "Float": ["FLOAT", "DOUBLE", "DECIMAL", "NUMERIC", "REAL"],
                "String": ["VARCHAR", "CHAR", "TEXT", "NVARCHAR", "NCHAR"],
                "Date": ["DATE", "TIME", "DATETIME", "TIMESTAMP"],
                "Binary": ["BLOB", "BINARY", "VARBINARY"],
                "Boolean": ["BOOLEAN", "BOOL"],
                "JSON": ["JSON"]
            ]
        )
    }

    struct ConnectionConfig: Sendable {
        let additionalConnectionFields: [ConnectionField]
        let category: DatabaseCategory
        let tagline: String
        let hidesBuiltInPassword: Bool
        /// The driver takes no container name on the connection, so the built-in field would
        /// be a second, meaningless place to type one: an embedded engine reads it from the
        /// file it opens, Redis numbers its databases through its own field, and a key-value
        /// store may have no container at all.
        let hidesBuiltInDatabase: Bool
        let defaultUnixSocketPath: String?
        let defaultHost: String?

        init(
            additionalConnectionFields: [ConnectionField] = [],
            category: DatabaseCategory = .other,
            tagline: String = "",
            hidesBuiltInPassword: Bool = false,
            hidesBuiltInDatabase: Bool = false,
            defaultUnixSocketPath: String? = nil,
            defaultHost: String? = nil
        ) {
            self.additionalConnectionFields = additionalConnectionFields
            self.category = category
            self.tagline = tagline
            self.hidesBuiltInPassword = hidesBuiltInPassword
            self.hidesBuiltInDatabase = hidesBuiltInDatabase
            self.defaultUnixSocketPath = defaultUnixSocketPath
            self.defaultHost = defaultHost
        }

        static let defaults = ConnectionConfig()
    }

    func withIconName(_ newIconName: String) -> PluginMetadataSnapshot {
        PluginMetadataSnapshot(
            displayName: displayName, iconName: newIconName, defaultPort: defaultPort,
            requiresAuthentication: requiresAuthentication, supportsForeignKeys: supportsForeignKeys,
            supportsSchemaEditing: supportsSchemaEditing, isDownloadable: isDownloadable,
            primaryUrlScheme: primaryUrlScheme, parameterStyle: parameterStyle,
            navigationModel: navigationModel, explainVariants: explainVariants,
            pathFieldRole: pathFieldRole, supportsHealthMonitor: supportsHealthMonitor,
            urlSchemes: urlSchemes, postConnectActions: postConnectActions,
            brandColorHex: brandColorHex, queryLanguageName: queryLanguageName,
            editorLanguage: editorLanguage, connectionMode: connectionMode,
            supportsDatabaseSwitching: supportsDatabaseSwitching,
            supportsColumnReorder: supportsColumnReorder,
            capabilities: capabilities, schema: schema, editor: editor, connection: connection
        )
    }

    func withExplainVariants(_ newExplainVariants: [ExplainVariant]) -> PluginMetadataSnapshot {
        PluginMetadataSnapshot(
            displayName: displayName, iconName: iconName, defaultPort: defaultPort,
            requiresAuthentication: requiresAuthentication, supportsForeignKeys: supportsForeignKeys,
            supportsSchemaEditing: supportsSchemaEditing, isDownloadable: isDownloadable,
            primaryUrlScheme: primaryUrlScheme, parameterStyle: parameterStyle,
            navigationModel: navigationModel, explainVariants: newExplainVariants,
            pathFieldRole: pathFieldRole, supportsHealthMonitor: supportsHealthMonitor,
            urlSchemes: urlSchemes, postConnectActions: postConnectActions,
            brandColorHex: brandColorHex, queryLanguageName: queryLanguageName,
            editorLanguage: editorLanguage, connectionMode: connectionMode,
            supportsDatabaseSwitching: supportsDatabaseSwitching,
            supportsColumnReorder: supportsColumnReorder,
            capabilities: capabilities, schema: schema, editor: editor, connection: connection
        )
    }

    func withBranding(from source: PluginMetadataSnapshot) -> PluginMetadataSnapshot {
        PluginMetadataSnapshot(
            displayName: source.displayName, iconName: source.iconName, defaultPort: defaultPort,
            requiresAuthentication: requiresAuthentication, supportsForeignKeys: supportsForeignKeys,
            supportsSchemaEditing: supportsSchemaEditing, isDownloadable: isDownloadable,
            primaryUrlScheme: primaryUrlScheme, parameterStyle: parameterStyle,
            navigationModel: navigationModel, explainVariants: explainVariants,
            pathFieldRole: pathFieldRole, supportsHealthMonitor: supportsHealthMonitor,
            urlSchemes: urlSchemes, postConnectActions: postConnectActions,
            brandColorHex: source.brandColorHex, queryLanguageName: queryLanguageName,
            editorLanguage: editorLanguage, connectionMode: connectionMode,
            supportsDatabaseSwitching: supportsDatabaseSwitching,
            supportsColumnReorder: supportsColumnReorder,
            capabilities: capabilities, schema: schema, editor: editor, connection: connection
        )
    }

    func withIsDownloadable(_ newIsDownloadable: Bool) -> PluginMetadataSnapshot {
        PluginMetadataSnapshot(
            displayName: displayName, iconName: iconName, defaultPort: defaultPort,
            requiresAuthentication: requiresAuthentication, supportsForeignKeys: supportsForeignKeys,
            supportsSchemaEditing: supportsSchemaEditing, isDownloadable: newIsDownloadable,
            primaryUrlScheme: primaryUrlScheme, parameterStyle: parameterStyle,
            navigationModel: navigationModel, explainVariants: explainVariants,
            pathFieldRole: pathFieldRole, supportsHealthMonitor: supportsHealthMonitor,
            urlSchemes: urlSchemes, postConnectActions: postConnectActions,
            brandColorHex: brandColorHex, queryLanguageName: queryLanguageName,
            editorLanguage: editorLanguage, connectionMode: connectionMode,
            supportsDatabaseSwitching: supportsDatabaseSwitching,
            supportsColumnReorder: supportsColumnReorder,
            capabilities: capabilities, schema: schema, editor: editor, connection: connection
        )
    }

    func withSwitchRouting(from source: PluginMetadataSnapshot) -> PluginMetadataSnapshot {
        PluginMetadataSnapshot(
            displayName: displayName, iconName: iconName, defaultPort: defaultPort,
            requiresAuthentication: requiresAuthentication, supportsForeignKeys: supportsForeignKeys,
            supportsSchemaEditing: supportsSchemaEditing, isDownloadable: isDownloadable,
            primaryUrlScheme: primaryUrlScheme, parameterStyle: parameterStyle,
            navigationModel: navigationModel, explainVariants: explainVariants,
            pathFieldRole: pathFieldRole, supportsHealthMonitor: supportsHealthMonitor,
            urlSchemes: urlSchemes, postConnectActions: postConnectActions,
            brandColorHex: brandColorHex, queryLanguageName: queryLanguageName,
            editorLanguage: editorLanguage, connectionMode: connectionMode,
            supportsDatabaseSwitching: source.supportsDatabaseSwitching,
            supportsColumnReorder: supportsColumnReorder,
            capabilities: capabilities,
            schema: SchemaInfo(
                defaultSchemaName: source.schema.defaultSchemaName,
                defaultGroupName: schema.defaultGroupName,
                tableEntityName: schema.tableEntityName,
                containerEntityName: source.schema.containerEntityName,
                schemaEntityName: source.schema.schemaEntityName,
                defaultPrimaryKeyColumn: schema.defaultPrimaryKeyColumn,
                immutableColumns: schema.immutableColumns,
                systemDatabaseNames: schema.systemDatabaseNames,
                systemSchemaNames: schema.systemSchemaNames,
                fileExtensions: schema.fileExtensions,
                fileSignatures: schema.fileSignatures,
                databaseGroupingStrategy: source.schema.databaseGroupingStrategy,
                structureColumnFields: schema.structureColumnFields
            ),
            editor: editor, connection: connection
        )
    }
}

final class PluginMetadataRegistry: @unchecked Sendable {
    static let shared = PluginMetadataRegistry()

    private let lock = NSLock()
    private var snapshots: [String: PluginMetadataSnapshot] = [:]
    private var defaultSnapshots: [String: PluginMetadataSnapshot] = [:]
    private var schemeIndex: [String: String] = [:]
    private var reverseTypeIndex: [String: String] = [:]

    private init() {
        registerBuiltInDefaults()
    }

    private func registerBuiltInDefaults() {
        let allDefaults = Self.curatedDefaults() + registryPluginDefaults()
        for entry in allDefaults {
            snapshots[entry.typeId] = entry.snapshot
            defaultSnapshots[entry.typeId] = entry.snapshot
            for scheme in entry.snapshot.urlSchemes {
                schemeIndex[scheme.lowercased()] = entry.typeId
            }
        }

        reverseTypeIndex["MariaDB"] = "MySQL"
        reverseTypeIndex["Redshift"] = "PostgreSQL"
        reverseTypeIndex["CockroachDB"] = "PostgreSQL"
        reverseTypeIndex["PGlite"] = "PostgreSQL"
        reverseTypeIndex["ScyllaDB"] = "Cassandra"
        reverseTypeIndex["Turso"] = "libSQL"
    }

    func register(snapshot: PluginMetadataSnapshot, forTypeId typeId: String, preserveIcon: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        registerLocked(snapshot: snapshot, forTypeId: typeId, preserveIcon: preserveIcon)
    }

    /// Registers an additional database type served by a multi-type plugin (Redshift,
    /// CockroachDB, PGlite on the PostgreSQL plugin). A plugin's statics are per-class, so
    /// they cannot express per-type facts like PGlite's disabled SSL or single-connection limit.
    /// The curated built-in entry is therefore authoritative for a variant; the plugin fills the
    /// EXPLAIN variants the curated entry leaves open, and supplies the editor config. A variant
    /// with no curated entry falls back to deriving its snapshot from the plugin.
    func registerVariant(
        pluginSnapshot: PluginMetadataSnapshot,
        forTypeId typeId: String,
        primaryTypeId: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let curated = defaultSnapshots[typeId] else {
            registerLocked(snapshot: pluginSnapshot, forTypeId: typeId, preserveIcon: true)
            return
        }
        var resolved = curated.explainVariants.isEmpty && !pluginSnapshot.explainVariants.isEmpty
            ? curated.withExplainVariants(pluginSnapshot.explainVariants)
            : curated
        Self.adoptPluginEditorConfig(
            &resolved,
            pluginSnapshot: pluginSnapshot,
            curatedPrimary: defaultSnapshots[primaryTypeId]
        )
        registerLocked(snapshot: resolved, forTypeId: typeId, preserveIcon: false)
    }

    private func registerLocked(snapshot: PluginMetadataSnapshot, forTypeId typeId: String, preserveIcon: Bool) {
        var resolved = snapshot
        if preserveIcon, let existing = snapshots[typeId] {
            resolved = resolved.withBranding(from: existing)
        }
        if let registryDefault = defaultSnapshots[typeId] {
            resolved = resolved.withIsDownloadable(registryDefault.isDownloadable)
            Self.adoptCuratedCaseSensitivity(&resolved, registryDefault: registryDefault)
            if Self.declaresLegacySchemaOnlyRouting(resolved, registryDefault: registryDefault) {
                Logger(subsystem: "com.TablePro", category: "PluginMetadataRegistry").notice(
                    "Plugin '\(typeId, privacy: .public)' declares legacy two-tier switching for a schema-only engine; applying the app's switch routing"
                )
                resolved = resolved.withSwitchRouting(from: registryDefault)
            }
        }
        snapshots[typeId] = resolved
        for scheme in resolved.urlSchemes {
            schemeIndex[scheme.lowercased()] = typeId
        }
    }

    func unregister(typeId: String) {
        lock.lock()
        defer { lock.unlock() }
        let previous = snapshots.removeValue(forKey: typeId)
        if let registryDefault = defaultSnapshots[typeId] {
            snapshots[typeId] = registryDefault
            for scheme in registryDefault.urlSchemes {
                schemeIndex[scheme.lowercased()] = typeId
            }
            return
        }
        if let previous {
            for scheme in previous.urlSchemes {
                schemeIndex.removeValue(forKey: scheme.lowercased())
            }
        }
    }

    /// A raw lookup by the exact id a snapshot was registered under, for the callers that hold an
    /// id rather than a type: registration itself, and iteration over `allRegisteredTypeIds()`.
    ///
    /// It is deliberately not named `snapshot(forTypeId:)` any more. That spelling read as the
    /// way to ask about a `DatabaseType`, so 62 call sites passed it `databaseType.pluginTypeId`
    /// and every variant was answered with its primary's facts. Asking about a type is
    /// `snapshot(for:)`; this overload cannot be reached from a `DatabaseType` without first
    /// choosing which id you mean, which is the point.
    func snapshot(forRegisteredTypeId typeId: String) -> PluginMetadataSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[typeId]
    }

    /// The snapshot describing a database type, which for a variant is its own curated entry
    /// rather than the entry of the plugin that serves it. Reaching a snapshot through
    /// `pluginTypeId` asks the primary instead, which is how a Redshift tab came to be told
    /// PostgreSQL's `ILIKE` folds non-ASCII, and how PGlite came to be offered the SSH, SSL,
    /// Cloudflare Tunnel and SOCKS panes its own entry declares it does not support.
    ///
    /// The fallback covers a type registered by a plugin with no curated entry of its own, where
    /// the primary's snapshot is the only one there is.
    ///
    /// This is the only way to read a snapshot for a `DatabaseType`. `pluginTypeId` answers a
    /// different question, "which plugin serves this type", and belongs to driver lookup alone.
    func snapshot(for databaseType: DatabaseType) -> PluginMetadataSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        if let own = snapshots[databaseType.rawValue] { return own }
        guard let primary = reverseTypeIndex[databaseType.rawValue] else { return nil }
        return snapshots[primary]
    }

    func typeId(forUrlScheme scheme: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return schemeIndex[scheme.lowercased()]
    }

    func databaseType(forUrlScheme scheme: String) -> DatabaseType? {
        guard let typeId = typeId(forUrlScheme: scheme) else { return nil }
        return DatabaseType(rawValue: typeId)
    }

    // MARK: - Dynamic Type Registration

    /// Registers an alias type ID that maps to a primary type ID.
    /// Used for multi-type plugins (e.g., MariaDB → MySQL, Redshift → PostgreSQL).
    func registerTypeAlias(_ aliasTypeId: String, primaryTypeId: String) {
        lock.lock()
        defer { lock.unlock() }
        reverseTypeIndex[aliasTypeId] = primaryTypeId
    }

    /// The inverse of `registerTypeAlias`. `unregister(typeId:)` drops a snapshot and leaves the
    /// alias behind, so a test that registers one has nothing to undo it with.
    func removeTypeAlias(_ aliasTypeId: String) {
        lock.lock()
        defer { lock.unlock() }
        reverseTypeIndex.removeValue(forKey: aliasTypeId)
    }

    /// Returns all registered type IDs (sorted for deterministic UI ordering).
    func allRegisteredTypeIds() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(snapshots.keys).sorted()
    }

    /// Resolves a database type raw value to its plugin type ID for driver lookup.
    /// For multi-type plugins (MySQL serves MariaDB), maps the alias to the primary.
    ///
    /// This is the answer to "which plugin serves this type", never "what is this type like".
    /// A snapshot read for a `DatabaseType` belongs in `snapshot(for:)`, which asks the variant
    /// first; `snapshot(forTypeId:)` is for a bare id that is already the one you want.
    func pluginTypeId(for rawValue: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return reverseTypeIndex[rawValue] ?? rawValue
    }

    /// Checks if a type ID is registered (has a snapshot).
    func hasType(_ typeId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[typeId] != nil
    }

    // MARK: - Snapshot Builder

    /// Builds a PluginMetadataSnapshot from a DriverPlugin's protocol properties.
    /// Used by PluginManager to self-register plugins at load time.
    func buildMetadataSnapshot(
        from driverType: any DriverPlugin.Type,
        isDownloadable: Bool = false
    ) -> PluginMetadataSnapshot {
        let parameterStyle = driverType.parameterStyle
        let schemes = driverType.urlSchemes
        let primaryScheme = schemes.first ?? driverType.databaseTypeId.lowercased()

        // A capability with no DriverPlugin static is curated per type, so it has to be carried
        // over from the built-in snapshot or plugin registration silently resets it to the
        // struct default. Cannot read these from driverType directly: stale plugins without
        // the property crash with EXC_BAD_INSTRUCTION (missing witness table entry).
        let existingSnapshot = snapshot(forRegisteredTypeId: driverType.databaseTypeId)

        return PluginMetadataSnapshot(
            displayName: driverType.databaseDisplayName,
            iconName: driverType.iconName,
            defaultPort: driverType.defaultPort,
            requiresAuthentication: driverType.requiresAuthentication,
            supportsForeignKeys: driverType.supportsForeignKeys,
            supportsSchemaEditing: driverType.supportsSchemaEditing,
            isDownloadable: isDownloadable,
            primaryUrlScheme: primaryScheme,
            parameterStyle: parameterStyle,
            navigationModel: driverType.navigationModel,
            explainVariants: driverType.explainVariants,
            pathFieldRole: driverType.pathFieldRole,
            supportsHealthMonitor: driverType.supportsHealthMonitor,
            urlSchemes: schemes,
            postConnectActions: driverType.postConnectActions,
            brandColorHex: driverType.brandColorHex,
            queryLanguageName: driverType.queryLanguageName,
            editorLanguage: driverType.editorLanguage,
            connectionMode: driverType.connectionMode,
            supportsDatabaseSwitching: driverType.supportsDatabaseSwitching,
            supportsColumnReorder: existingSnapshot?.supportsColumnReorder ?? false,
            capabilities: PluginMetadataSnapshot.CapabilityFlags(
                supportsSchemaSwitching: driverType.supportsSchemaSwitching,
                supportsImport: driverType.supportsImport,
                supportsExport: driverType.supportsExport,
                supportsSSH: driverType.supportsSSH,
                supportsSSL: driverType.supportsSSL,
                supportsCascadeDrop: driverType.supportsCascadeDrop,
                supportsForeignKeyDisable: driverType.supportsForeignKeyDisable,
                supportsReadOnlyMode: driverType.supportsReadOnlyMode,
                supportsQueryProgress: driverType.supportsQueryProgress,
                requiresReconnectForDatabaseSwitch: driverType.requiresReconnectForDatabaseSwitch,
                supportsDropDatabase: driverType.supportsDropDatabase,
                supportsRenameTable: driverType.supportsRenameTable,
                supportsRenameView: driverType.supportsRenameView,
                supportsRenameDatabase: driverType.supportsRenameDatabase,
                supportsRenameSchema: driverType.supportsRenameSchema,
                supportsDropSchema: driverType.supportsDropSchema,
                supportsAddColumn: driverType.supportsAddColumn,
                supportsModifyColumn: driverType.supportsModifyColumn,
                supportsDropColumn: driverType.supportsDropColumn,
                supportsRenameColumn: driverType.supportsRenameColumn,
                supportsAddIndex: driverType.supportsAddIndex,
                supportsDropIndex: driverType.supportsDropIndex,
                supportsModifyPrimaryKey: driverType.supportsModifyPrimaryKey,
                supportsTriggers: driverType.supportsTriggers,
                supportsTriggerEditing: driverType.supportsTriggerEditing,
                supportsCheckConstraints: driverType.supportsCheckConstraints,
                supportsCheckConstraintEditing: driverType.supportsCheckConstraintEditing,
                supportsGeneratedColumns: driverType.supportsGeneratedColumns,
                supportsRoutines: driverType.supportsRoutines,
                supportsDatabaseTriggerBrowse: driverType.supportsDatabaseTriggerBrowse,
                defaultSSLMode: existingSnapshot?.capabilities.defaultSSLMode ?? .disabled,
                supportsOpportunisticTLS: existingSnapshot?.capabilities.supportsOpportunisticTLS ?? true,
                supportsCloudflareTunnel: driverType.supportsSSH,
                supportsClientKeyPassphrase: existingSnapshot?.capabilities.supportsClientKeyPassphrase ?? false,
                supportsConnectionPooling: existingSnapshot?.capabilities.supportsConnectionPooling ?? true,
                authenticationIsDatabaseScoped: existingSnapshot?.capabilities
                    .authenticationIsDatabaseScoped ?? false,
                localFilePathField: existingSnapshot?.capabilities.localFilePathField,
                supportsRemoteDatabaseFile: existingSnapshot?.capabilities
                    .supportsRemoteDatabaseFile ?? false
            ),
            schema: PluginMetadataSnapshot.SchemaInfo(
                defaultSchemaName: driverType.defaultSchemaName,
                defaultGroupName: driverType.defaultGroupName,
                tableEntityName: driverType.tableEntityName,
                containerEntityName: driverType.containerEntityName,
                schemaEntityName: driverType.schemaEntityName,
                defaultPrimaryKeyColumn: driverType.defaultPrimaryKeyColumn,
                immutableColumns: driverType.immutableColumns,
                systemDatabaseNames: driverType.systemDatabaseNames,
                systemSchemaNames: driverType.systemSchemaNames,
                fileExtensions: driverType.fileExtensions,
                fileSignatures: existingSnapshot?.schema.fileSignatures ?? [],
                databaseGroupingStrategy: driverType.databaseGroupingStrategy,
                structureColumnFields: driverType.structureColumnFields
            ),
            editor: PluginMetadataSnapshot.EditorConfig(
                sqlDialect: driverType.sqlDialect,
                statementCompletions: driverType.statementCompletions,
                columnTypesByCategory: driverType.columnTypesByCategory
            ),
            connection: PluginMetadataSnapshot.ConnectionConfig(
                additionalConnectionFields: driverType.additionalConnectionFields,
                category: existingSnapshot?.connection.category
                    ?? Self.fallbackCategory(forTypeId: driverType.databaseTypeId),
                tagline: existingSnapshot?.connection.tagline
                    ?? Self.fallbackTagline(forTypeId: driverType.databaseTypeId),
                hidesBuiltInPassword: existingSnapshot?.connection.hidesBuiltInPassword ?? false,
                hidesBuiltInDatabase: existingSnapshot?.connection.hidesBuiltInDatabase ?? false,
                defaultUnixSocketPath: existingSnapshot?.connection.defaultUnixSocketPath,
                defaultHost: existingSnapshot?.connection.defaultHost
            )
        )
    }

    // MARK: - Category / Tagline Fallback Table

    /// Seed table for plugin types that don't have a built-in snapshot yet (separately distributed plugins).
    /// Keyed by `databaseTypeId`. Stale plugins from the registry inherit these on registration.
    static func fallbackCategory(forTypeId typeId: String) -> DatabaseCategory {
        switch typeId {
        case "MySQL", "MariaDB", "PostgreSQL", "SQLite", "Oracle", "MSSQL":
            return .relational
        case "Redshift", "ClickHouse", "DuckDB", "BigQuery":
            return .analytical
        case "MongoDB", "Elasticsearch", "SurrealDB":
            return .document
        case "Redis":
            return .keyValue
        case "Cassandra", "ScyllaDB":
            return .wideColumn
        case "etcd", "Etcd":
            return .coordination
        case "Cloudflare D1", "libSQL", "DynamoDB":
            return .cloud
        case "Kafka":
            return .streaming
        default:
            return .other
        }
    }

    static func fallbackTagline(forTypeId typeId: String) -> String {
        switch typeId {
        case "MySQL":          return String(localized: "Most popular open-source SQL database")
        case "MariaDB":        return String(localized: "Open-source fork of MySQL")
        case "PostgreSQL":     return String(localized: "Advanced object-relational SQL")
        case "Redshift":       return String(localized: "Amazon's columnar warehouse on Postgres")
        case "SQLite":         return String(localized: "Embedded zero-config SQL database")
        case "MSSQL":          return String(localized: "Microsoft's enterprise SQL database")
        case "Oracle":         return String(localized: "Enterprise SQL with PL/SQL")
        case "MongoDB":        return String(localized: "JSON-style document database")
        case "Elasticsearch":  return String(localized: "Search and analytics engine")
        case "Redis":          return String(localized: "In-memory data store and cache")
        case "ClickHouse":     return String(localized: "Column-oriented OLAP for big data")
        case "DuckDB":         return String(localized: "Embedded analytical SQL")
        case "Cassandra":      return String(localized: "Distributed wide-column store")
        case "ScyllaDB":       return String(localized: "C++ rewrite of Cassandra, faster")
        case "etcd", "Etcd":   return String(localized: "Distributed key-value store for service discovery")
        case "Cloudflare D1":  return String(localized: "Serverless SQLite at the edge")
        case "libSQL":         return String(localized: "Distributed SQLite by Turso")
        case "DynamoDB":       return String(localized: "AWS managed key-value/document store")
        case "BigQuery":       return String(localized: "Google Cloud serverless data warehouse")
        case "SurrealDB":      return String(localized: "Multi-model database with SurrealQL")
        case "Kafka":          return String(localized: "Event streaming platform")
        default:               return ""
        }
    }

    func allFileExtensions() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String: String] = [:]
        for (typeId, snapshot) in snapshots {
            for ext in snapshot.schema.fileExtensions {
                let key = ext.lowercased()
                if result[key] == nil {
                    result[key] = typeId
                }
            }
        }
        return result
    }

    func allFileSignatures() -> [String: [DatabaseFileSignature]] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String: [DatabaseFileSignature]] = [:]
        for (typeId, snapshot) in snapshots where !snapshot.schema.fileSignatures.isEmpty {
            result[typeId] = snapshot.schema.fileSignatures
        }
        return result
    }

    func allUrlSchemes() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return schemeIndex
    }
}
