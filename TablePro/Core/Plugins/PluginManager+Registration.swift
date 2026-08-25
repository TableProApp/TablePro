//
//  PluginManager+Registration.swift
//  TablePro
//

import Foundation
import os
import Security
import SwiftUI
import TableProPluginKit

// MARK: - Capability Registration

extension PluginManager {
    func registerCapabilities(_ instance: any TableProPlugin, pluginId: String) {
        let declared = Set(type(of: instance).capabilities)
        var registeredAny = false

        if let driver = instance as? any DriverPlugin {
            if !declared.contains(.databaseDriver) {
                Self.logger.warning("Plugin '\(pluginId)' conforms to DriverPlugin but does not declare .databaseDriver capability - registering anyway")
            }
            do {
                try validateDriverDescriptor(type(of: driver), pluginId: pluginId)
            } catch {
                Self.logger.error("Plugin '\(pluginId)' driver rejected: \(error.localizedDescription)")
                return
            }
            if !driverPlugins.keys.contains(type(of: driver).databaseTypeId) {
                let driverType = type(of: driver)
                let typeId = driverType.databaseTypeId
                driverPlugins[typeId] = driver
                for additionalId in driverType.additionalDatabaseTypeIds {
                    driverPlugins[additionalId] = driver
                }

                let snapshot = PluginMetadataRegistry.shared.buildMetadataSnapshot(
                    from: driverType,
                    isDownloadable: driverType.isDownloadable
                )
                if snapshot.schema.databaseGroupingStrategy == .hierarchicalSchema, snapshot.supportsDatabaseSwitching {
                    Self.logger.warning("Plugin '\(pluginId)' declares hierarchicalSchema grouping together with supportsDatabaseSwitching; schema-only engines must declare supportsDatabaseSwitching = false or the container switcher misroutes")
                }
                PluginMetadataRegistry.shared.register(snapshot: snapshot, forTypeId: typeId, preserveIcon: true)
                for additionalId in driverType.additionalDatabaseTypeIds {
                    PluginMetadataRegistry.shared.registerVariant(
                        pluginSnapshot: snapshot,
                        forTypeId: additionalId,
                        primaryTypeId: typeId
                    )
                    PluginMetadataRegistry.shared.registerTypeAlias(additionalId, primaryTypeId: typeId)
                }

                Self.logger.debug("Registered driver plugin '\(pluginId)' for database type '\(typeId)'")
                registeredAny = true
            }
        }

        if let exportPlugin = instance as? any ExportFormatPlugin {
            if !declared.contains(.exportFormat) {
                Self.logger.warning("Plugin '\(pluginId)' conforms to ExportFormatPlugin but does not declare .exportFormat capability - registering anyway")
            }
            let formatId = type(of: exportPlugin).formatId
            exportPlugins[formatId] = exportPlugin
            Self.logger.debug("Registered export plugin '\(pluginId)' for format '\(formatId)'")
            registeredAny = true
        }

        if let importPlugin = instance as? any ImportFormatPlugin {
            if !declared.contains(.importFormat) {
                Self.logger.warning("Plugin '\(pluginId)' conforms to ImportFormatPlugin but does not declare .importFormat capability - registering anyway")
            }
            let formatId = type(of: importPlugin).formatId
            importPlugins[formatId] = importPlugin
            Self.logger.debug("Registered import plugin '\(pluginId)' for format '\(formatId)'")
            registeredAny = true
        }

        if let inspectorPlugin = instance as? any DocumentInspectorPlugin {
            if !declared.contains(.documentInspector) {
                Self.logger.warning("Plugin '\(pluginId)' conforms to DocumentInspectorPlugin but does not declare .documentInspector capability - registering anyway")
            }
            let inspectorId = type(of: inspectorPlugin).inspectorId
            inspectorPlugins[inspectorId] = inspectorPlugin
            Self.logger.debug("Registered inspector plugin '\(pluginId)' for id '\(inspectorId)'")
            registeredAny = true
        }

        if registeredAny {
            pluginInstances[pluginId] = instance
        }
    }

    func validateCapabilityDeclarations(_ pluginType: any TableProPlugin.Type, pluginId: String) {
        let declared = Set(pluginType.capabilities)
        let isDriver = pluginType is any DriverPlugin.Type
        let isExporter = pluginType is any ExportFormatPlugin.Type
        let isImporter = pluginType is any ImportFormatPlugin.Type
        let isInspector = pluginType is any DocumentInspectorPlugin.Type

        if declared.contains(.databaseDriver) && !isDriver {
            Self.logger.warning("Plugin '\(pluginId)' declares .databaseDriver but does not conform to DriverPlugin")
        }
        if declared.contains(.exportFormat) && !isExporter {
            Self.logger.warning("Plugin '\(pluginId)' declares .exportFormat but does not conform to ExportFormatPlugin")
        }
        if declared.contains(.importFormat) && !isImporter {
            Self.logger.warning("Plugin '\(pluginId)' declares .importFormat but does not conform to ImportFormatPlugin")
        }
        if declared.contains(.documentInspector) && !isInspector {
            Self.logger.warning("Plugin '\(pluginId)' declares .documentInspector but does not conform to DocumentInspectorPlugin")
        }
    }

    // MARK: - Descriptor Validation

    /// Reject-level validation: runs synchronously before registration.
    /// Checks only properties already accessed during the loading flow.
    func validateDriverDescriptor(_ driverType: any DriverPlugin.Type, pluginId: String) throws {
        guard !driverType.databaseTypeId.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PluginError.invalidDescriptor(pluginId: pluginId, reason: "databaseTypeId is empty")
        }

        guard !driverType.databaseDisplayName.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PluginError.invalidDescriptor(pluginId: pluginId, reason: "databaseDisplayName is empty")
        }

        let typeId = driverType.databaseTypeId
        if driverPlugins[typeId] != nil {
            let existingName = PluginMetadataRegistry.shared
                .snapshot(forRegisteredTypeId: typeId)?.displayName ?? typeId
            throw PluginError.invalidDescriptor(
                pluginId: pluginId,
                reason: "databaseTypeId '\(typeId)' is already registered by '\(existingName)'"
            )
        }

        let allAdditionalIds = driverType.additionalDatabaseTypeIds
        if allAdditionalIds.contains(typeId) {
            Self.logger.warning("Plugin '\(pluginId)': additionalDatabaseTypeIds contains the primary databaseTypeId '\(typeId)'")
        }

        for additionalId in allAdditionalIds {
            if driverPlugins[additionalId] != nil {
                let existingName = PluginMetadataRegistry.shared
                    .snapshot(forRegisteredTypeId: additionalId)?.displayName ?? additionalId
                throw PluginError.invalidDescriptor(
                    pluginId: pluginId,
                    reason: "additionalDatabaseTypeId '\(additionalId)' is already registered by '\(existingName)'"
                )
            }
        }
    }

    /// Warn-level connection field validation. Called lazily on first access via
    /// `additionalConnectionFields(for:)`, not during plugin loading (protocol witness
    /// tables may be unstable for dynamically loaded bundles during the loading path).
    func validateConnectionFields(_ fields: [ConnectionField], pluginId: String) {
        var seenIds = Set<String>()
        for field in fields {
            if field.id.trimmingCharacters(in: .whitespaces).isEmpty {
                Self.logger.warning("Plugin '\(pluginId)': connection field has empty id")
            }
            if field.label.trimmingCharacters(in: .whitespaces).isEmpty {
                Self.logger.warning("Plugin '\(pluginId)': connection field '\(field.id)' has empty label")
            }
            if !seenIds.insert(field.id).inserted {
                Self.logger.warning("Plugin '\(pluginId)': duplicate connection field id '\(field.id)'")
            }
            if case .dropdown(let options) = field.fieldType, options.isEmpty {
                Self.logger.warning("Plugin '\(pluginId)': connection field '\(field.id)' is a dropdown with no options")
            }
        }
    }

    func validateDialectDescriptor(_ dialect: SQLDialectDescriptor, pluginId: String) {
        if dialect.identifierQuote.trimmingCharacters(in: .whitespaces).isEmpty {
            Self.logger.warning("Plugin '\(pluginId)': sqlDialect.identifierQuote is empty")
        }
        if dialect.keywords.isEmpty {
            Self.logger.warning("Plugin '\(pluginId)': sqlDialect.keywords is empty")
        }
    }

    // MARK: - Available Database Types

    /// All database types with loaded plugins, ordered by display name.
    var availableDatabaseTypes: [DatabaseType] {
        var types: [DatabaseType] = []
        for entry in plugins where entry.isEnabled {
            if let typeId = entry.databaseTypeId {
                types.append(DatabaseType(rawValue: typeId))
            }
            for additionalId in entry.additionalTypeIds {
                types.append(DatabaseType(rawValue: additionalId))
            }
        }
        return types.sorted { $0.rawValue < $1.rawValue }
    }

    var allAvailableDatabaseTypes: [DatabaseType] {
        var types = Set(availableDatabaseTypes)
        for type in DatabaseType.allKnownTypes {
            types.insert(type)
        }
        return types.sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: - Driver Availability

    func isDriverInstalled(for databaseType: DatabaseType) -> Bool {
        let typeId = databaseType.pluginTypeId
        return driverPlugins[typeId] != nil || lazyDriverURLs[typeId] != nil
    }

    func sqlDialect(for databaseType: DatabaseType) -> SQLDialectDescriptor? {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?.editor.sqlDialect
    }

    /// How this engine can express case-insensitive matching. SQL engines answer from their
    /// dialect; document stores have no dialect and declare it on the plugin directly.
    func caseSensitivityStyle(for databaseType: DatabaseType) -> SQLDialectDescriptor.CaseSensitivityStyle {
        if let dialect = sqlDialect(for: databaseType) {
            return dialect.caseSensitivityStyle
        }
        guard let plugin = driverPlugin(for: databaseType) else { return .unsupported }
        return type(of: plugin).caseSensitivityStyle
    }

    func statementCompletions(for databaseType: DatabaseType) -> [CompletionEntry] {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?.editor.statementCompletions ?? []
    }

    func additionalConnectionFields(for databaseType: DatabaseType) -> [ConnectionField] {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .connection.additionalConnectionFields ?? []
    }

    /// Every secure field id a stored connection of this type could be holding, which is the
    /// variant's own declared fields UNION its serving plugin's.
    ///
    /// Deletion, Keychain cleanup and export redaction all need a superset, and they are the
    /// reason this is not `additionalConnectionFields(for:).filter(\.isSecure)`. A variant used to
    /// be offered the primary's whole form, so a PGlite connection saved before that was fixed can
    /// still hold an AWS secret under a field PGlite itself never declared. Narrowing the list to
    /// what the form renders today would orphan that value in the Keychain and, worse, stop
    /// redacting it on export. Rendering a form is the opposite requirement and stays exact.
    func secureConnectionFieldIds(for databaseType: DatabaseType) -> [String] {
        let own = PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .connection.additionalConnectionFields ?? []
        let serving = PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: databaseType.pluginTypeId)?
            .connection.additionalConnectionFields ?? []
        var ids: [String] = []
        for field in own + serving where field.isSecure && !ids.contains(field.id) {
            ids.append(field.id)
        }
        return ids
    }

    // MARK: - Plugin Property Lookups

    func driverPlugin(for databaseType: DatabaseType) -> (any DriverPlugin)? {
        let typeId = databaseType.pluginTypeId
        if let driver = driverPlugins[typeId] { return driver }
        activateDriver(databaseTypeId: typeId)
        return driverPlugins[typeId]
    }

    func exportPlugin(forFormat formatId: String) -> (any ExportFormatPlugin)? {
        if let plugin = exportPlugins[formatId] { return plugin }
        activateExportFormat(formatId)
        return exportPlugins[formatId]
    }

    func importPlugin(forFormat formatId: String) -> (any ImportFormatPlugin)? {
        if let plugin = importPlugins[formatId] { return plugin }
        activateImportFormat(formatId)
        return importPlugins[formatId]
    }

    func allExportPlugins() -> [any ExportFormatPlugin] {
        for formatId in allLazyExportFormatIds() {
            activateExportFormat(formatId)
        }
        return Array(exportPlugins.values)
    }

    func allImportPlugins() -> [any ImportFormatPlugin] {
        for formatId in allLazyImportFormatIds() {
            activateImportFormat(formatId)
        }
        return Array(importPlugins.values)
    }

    func importPlugins(for databaseType: DatabaseType) -> [any ImportFormatPlugin] {
        guard supportsImport(for: databaseType) else { return [] }
        let typeId = databaseType.rawValue
        return allImportPlugins()
            .filter { plugin in
                let supported = type(of: plugin).supportedDatabaseTypeIds
                let excluded = type(of: plugin).excludedDatabaseTypeIds
                if !supported.isEmpty && !supported.contains(typeId) { return false }
                if excluded.contains(typeId) { return false }
                return true
            }
            .sorted { lhs, rhs in
                let lhsRowBased = type(of: lhs).requiresTargetTable
                let rhsRowBased = type(of: rhs).requiresTargetTable
                if lhsRowBased != rhsRowBased { return !lhsRowBased }
                return type(of: lhs).formatDisplayName < type(of: rhs).formatDisplayName
            }
    }

    func importFormatOptions(for databaseType: DatabaseType) -> [ImportFormatOption] {
        importPlugins(for: databaseType).map {
            ImportFormatOption(id: type(of: $0).formatId, name: type(of: $0).formatDisplayName)
        }
    }

    /// Returns a temporary plugin driver for query building (buildBrowseQuery), or nil
    /// if the plugin doesn't implement custom query building (NoSQL hooks).
    func queryBuildingDriver(for databaseType: DatabaseType) -> (any PluginDatabaseDriver)? {
        let typeId = databaseType.pluginTypeId
        if let cached = queryBuildingDriverCache[typeId] { return cached }
        guard let plugin = driverPlugin(for: databaseType) else {
            if hasFinishedInitialLoad {
                queryBuildingDriverCache[typeId] = .some(nil)
            }
            return nil
        }
        let config = DriverConnectionConfig(host: "", port: 0, username: "", password: "", database: "")
        let driver = plugin.createDriver(config: config)
        let result: (any PluginDatabaseDriver)? =
            driver.buildBrowseQuery(table: "_probe", sortColumns: [], columns: [], limit: 1, offset: 0) != nil
            ? driver : nil
        if hasFinishedInitialLoad {
            queryBuildingDriverCache[typeId] = .some(result)
        }
        return result
    }

    func editorLanguage(for databaseType: DatabaseType) -> EditorLanguage {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?.editorLanguage ?? .sql
    }

    func queryLanguageName(for databaseType: DatabaseType) -> String {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .queryLanguageName ?? "SQL"
    }

    func connectionMode(for databaseType: DatabaseType) -> ConnectionMode {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .connectionMode ?? .network
    }

    func brandColor(for databaseType: DatabaseType) -> Color {
        if let hex = PluginMetadataRegistry.shared.snapshot(for: databaseType)?.brandColorHex {
            return Color(hex: hex)
        }
        return Color.gray
    }

    func supportsDatabaseSwitching(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .supportsDatabaseSwitching ?? true
    }

    func supportsSchemaSwitching(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .capabilities.supportsSchemaSwitching ?? false
    }

    /// Every container dimension the engine can switch, ordered outermost first. An engine can have
    /// both, which is why this is a list: PostgreSQL browses a database and a schema within it, and
    /// naming only one of them is what left the schema with no control of its own.
    func switchableContainers(for databaseType: DatabaseType) -> [ContainerSwitchTarget] {
        var targets: [ContainerSwitchTarget] = []
        if supportsDatabaseSwitching(for: databaseType) {
            targets.append(.database)
        }
        if supportsSchemaSwitching(for: databaseType) {
            targets.append(.schema)
        }
        return targets
    }

    /// The dimension a tab and a workspace are anchored to, which is the outermost one the engine
    /// switches. Derived from `switchableContainers` so the two orderings cannot drift apart.
    /// This is not "the dimension the user can switch": read `switchableContainers` for that.
    func containerSwitchTarget(for databaseType: DatabaseType) -> ContainerSwitchTarget? {
        switchableContainers(for: databaseType).first
    }

    func supportsContainerSwitching(for databaseType: DatabaseType) -> Bool {
        containerSwitchTarget(for: databaseType) != nil
    }

    func supportsImport(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .capabilities.supportsImport ?? true
    }

    func systemDatabaseNames(for databaseType: DatabaseType) -> [String] {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .schema.systemDatabaseNames ?? []
    }

    func systemSchemaNames(for databaseType: DatabaseType) -> [String] {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .schema.systemSchemaNames ?? []
    }

    func columnTypesByCategory(for databaseType: DatabaseType) -> [String: [String]] {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .editor.columnTypesByCategory ?? PluginMetadataSnapshot.EditorConfig.defaults.columnTypesByCategory
    }

    func requiresAuthentication(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .requiresAuthentication ?? true
    }

    func fileExtensions(for databaseType: DatabaseType) -> [String] {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .schema.fileExtensions ?? []
    }

    func tableEntityName(for databaseType: DatabaseType) -> String {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .schema.tableEntityName ?? "Tables"
    }

    func containerEntityName(for databaseType: DatabaseType) -> String {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .schema.containerEntityName ?? "Database"
    }

    func defaultUnixSocketPath(for databaseType: DatabaseType) -> String? {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .connection.defaultUnixSocketPath
    }

    func containerEntityNamePlural(for databaseType: DatabaseType) -> String {
        containerEntityName(for: databaseType) + "s"
    }

    func schemaEntityName(for databaseType: DatabaseType) -> String {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .schema.schemaEntityName ?? "Schema"
    }

    func schemaEntityNamePlural(for databaseType: DatabaseType) -> String {
        schemaEntityName(for: databaseType) + "s"
    }

    func supportsCascadeDrop(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .capabilities.supportsCascadeDrop ?? false
    }

    func supportsForeignKeyDisable(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .capabilities.supportsForeignKeyDisable ?? true
    }

    func immutableColumns(for databaseType: DatabaseType) -> [String] {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .schema.immutableColumns ?? []
    }

    func supportsReadOnlyMode(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .capabilities.supportsReadOnlyMode ?? true
    }

    func defaultSchemaName(for databaseType: DatabaseType) -> String {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .schema.defaultSchemaName ?? "public"
    }

    func requiresReconnectForDatabaseSwitch(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .capabilities.requiresReconnectForDatabaseSwitch ?? false
    }

    func structureColumnFields(for databaseType: DatabaseType) -> [StructureColumnField] {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .schema.structureColumnFields ?? [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
    }

    func defaultPrimaryKeyColumn(for databaseType: DatabaseType) -> String? {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .schema.defaultPrimaryKeyColumn
    }

    func supportsQueryProgress(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .capabilities.supportsQueryProgress ?? false
    }

    func supportsSSH(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .capabilities.supportsSSH ?? true
    }

    func supportsSSL(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .capabilities.supportsSSL ?? true
    }

    func supportsCloudflareTunnel(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .capabilities.supportsCloudflareTunnel ?? true
    }

    func supportsSOCKSProxy(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .capabilities.supportsSOCKSProxy ?? true
    }

    func supportsColumnReorder(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .supportsColumnReorder ?? false
    }

    func supportsDropDatabase(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .capabilities.supportsDropDatabase ?? false
    }

    func supportsDropSchema(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .capabilities.supportsDropSchema ?? false
    }

    func autoLimitStyle(for databaseType: DatabaseType) -> AutoLimitStyle {
        guard let snapshot = PluginMetadataRegistry.shared.snapshot(for: databaseType) else {
            return .limit
        }
        guard let dialect = snapshot.editor.sqlDialect else { return .none }
        return dialect.autoLimitStyle
    }

    func usesTrueFalseBooleans(for databaseType: DatabaseType) -> Bool {
        sqlDialect(for: databaseType)?.booleanLiteralStyle == .truefalse
    }

    func paginationStyle(for databaseType: DatabaseType) -> SQLDialectDescriptor.PaginationStyle {
        sqlDialect(for: databaseType)?.paginationStyle ?? .limit
    }

    func offsetFetchOrderBy(for databaseType: DatabaseType) -> String {
        sqlDialect(for: databaseType)?.offsetFetchOrderBy ?? "ORDER BY (SELECT NULL)"
    }

    func databaseGroupingStrategy(for databaseType: DatabaseType) -> GroupingStrategy {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .schema.databaseGroupingStrategy ?? .byDatabase
    }

    /// A file holds exactly one database, so a file-based engine never has a tree to draw.
    /// Every other mode can: a server hosts several databases, and an embedded engine can
    /// attach them.
    ///
    /// Both remaining terms are permissive by default (`supportsDatabaseSwitching` is true
    /// and the grouping strategy is `.byDatabase` on `DriverPlugin`), so a plugin that
    /// declares neither gets a tree its default `fetchDatabases()` returns nothing for.
    /// That was true of networked plugins before this guard was widened and is why the
    /// list stays a declaration rather than an inference; `DatabaseTreeCapabilityTests`
    /// pins it for both modes.
    func supportsDatabaseTree(for databaseType: DatabaseType) -> Bool {
        Self.supportsDatabaseTree(
            connectionMode: connectionMode(for: databaseType),
            supportsDatabaseSwitching: supportsDatabaseSwitching(for: databaseType),
            grouping: databaseGroupingStrategy(for: databaseType)
        )
    }

    /// The rule itself, as a pure function of the three inputs, so it can be exercised for
    /// combinations no registered type declares today.
    static func supportsDatabaseTree(
        connectionMode: ConnectionMode,
        supportsDatabaseSwitching: Bool,
        grouping: GroupingStrategy
    ) -> Bool {
        guard connectionMode != .fileBased, supportsDatabaseSwitching else { return false }
        return grouping == .byDatabase || grouping == .bySchema
    }

    func defaultGroupName(for databaseType: DatabaseType) -> String {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?
            .schema.defaultGroupName ?? "main"
    }

    var allRegisteredFileExtensions: [String: DatabaseType] {
        let extMap = PluginMetadataRegistry.shared.allFileExtensions()
        var result: [String: DatabaseType] = [:]
        for (ext, typeId) in extMap {
            result[ext] = DatabaseType(rawValue: typeId)
        }
        return result
    }

    var allRegisteredURLSchemes: Set<String> {
        Set(PluginMetadataRegistry.shared.allUrlSchemes().keys)
    }

    func installMissingPlugin(
        for databaseType: DatabaseType,
        registryClient: RegistryClient = .shared,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let pluginTypeId = databaseType.pluginTypeId

        if let existingEntry = plugins.first(where: { entry in
            entry.databaseTypeId == pluginTypeId || entry.additionalTypeIds.contains(pluginTypeId)
        }) {
            if !existingEntry.isEnabled {
                setEnabled(true, pluginId: existingEntry.id)
            }
            if driverPlugins[pluginTypeId] != nil {
                Self.logger.info("Re-enabled existing plugin '\(existingEntry.name)' for '\(databaseType.rawValue)'")
                return
            }
            Self.logger.warning("Plugin '\(existingEntry.id)' exists but driver not registered, reinstalling")
            if existingEntry.source == .userInstalled {
                do {
                    try await uninstallPlugin(id: existingEntry.id)
                } catch {
                    Self.logger.warning("Failed to uninstall plugin '\(existingEntry.id)' before reinstall: \(error.localizedDescription)")
                }
            }
        }

        await registryClient.ensureManifest(.ifStale)
        var registryPlugin = Self.registryPlugin(forTypeId: pluginTypeId, in: registryClient.manifest)

        if registryPlugin == nil {
            await registryClient.ensureManifest(.mustBeCurrent)
            registryPlugin = Self.registryPlugin(forTypeId: pluginTypeId, in: registryClient.manifest)
        }

        guard let registryPlugin else {
            guard registryClient.fetchState == .loaded else {
                throw PluginError.registryUnreachable
            }
            throw PluginError.notFound
        }

        let entry = try await installFromRegistry(registryPlugin, registryClient: registryClient, progress: progress)
        Self.logger.info("Installed missing plugin '\(entry.name)' for database type '\(databaseType.rawValue)'")
    }

    nonisolated static func registryPlugin(forTypeId pluginTypeId: String, in manifest: RegistryManifest?) -> RegistryPlugin? {
        manifest?.plugins.first { $0.databaseTypeIds?.contains(pluginTypeId) == true }
    }
}
