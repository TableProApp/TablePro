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
                Self.logger.warning("Plugin '\(pluginId)' conforms to DriverPlugin but does not declare .databaseDriver capability — registering anyway")
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

                // Self-register plugin metadata from the DriverPlugin protocol.
                let snapshot = PluginMetadataRegistry.shared.buildMetadataSnapshot(
                    from: driverType,
                    isDownloadable: driverType.isDownloadable
                )
                PluginMetadataRegistry.shared.register(snapshot: snapshot, forTypeId: typeId, preserveIcon: true)
                for additionalId in driverType.additionalDatabaseTypeIds {
                    PluginMetadataRegistry.shared.register(snapshot: snapshot, forTypeId: additionalId, preserveIcon: true)
                    PluginMetadataRegistry.shared.registerTypeAlias(additionalId, primaryTypeId: typeId)
                }

                Self.logger.debug("Registered driver plugin '\(pluginId)' for database type '\(typeId)'")
                registeredAny = true
            }
        }

        if let exportPlugin = instance as? any ExportFormatPlugin {
            if !declared.contains(.exportFormat) {
                Self.logger.warning("Plugin '\(pluginId)' conforms to ExportFormatPlugin but does not declare .exportFormat capability — registering anyway")
            }
            let formatId = type(of: exportPlugin).formatId
            exportPlugins[formatId] = exportPlugin
            Self.logger.debug("Registered export plugin '\(pluginId)' for format '\(formatId)'")
            registeredAny = true
        }

        if let importPlugin = instance as? any ImportFormatPlugin {
            if !declared.contains(.importFormat) {
                Self.logger.warning("Plugin '\(pluginId)' conforms to ImportFormatPlugin but does not declare .importFormat capability — registering anyway")
            }
            let formatId = type(of: importPlugin).formatId
            importPlugins[formatId] = importPlugin
            Self.logger.debug("Registered import plugin '\(pluginId)' for format '\(formatId)'")
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

        if declared.contains(.databaseDriver) && !isDriver {
            Self.logger.warning("Plugin '\(pluginId)' declares .databaseDriver but does not conform to DriverPlugin")
        }
        if declared.contains(.exportFormat) && !isExporter {
            Self.logger.warning("Plugin '\(pluginId)' declares .exportFormat but does not conform to ExportFormatPlugin")
        }
        if declared.contains(.importFormat) && !isImporter {
            Self.logger.warning("Plugin '\(pluginId)' declares .importFormat but does not conform to ImportFormatPlugin")
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
                .snapshot(forTypeId: typeId)?.displayName ?? typeId
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
                    .snapshot(forTypeId: additionalId)?.displayName ?? additionalId
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

    func isDriverAvailable(for databaseType: DatabaseType) -> Bool {
        driverPlugins[databaseType.pluginTypeId] != nil
    }

    func isDriverLoaded(for databaseType: DatabaseType) -> Bool {
        driverPlugins[databaseType.pluginTypeId] != nil
    }

    func sqlDialect(for databaseType: DatabaseType) -> SQLDialectDescriptor? {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .editor.sqlDialect
    }

    func statementCompletions(for databaseType: DatabaseType) -> [CompletionEntry] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .editor.statementCompletions ?? []
    }

    func additionalConnectionFields(for databaseType: DatabaseType) -> [ConnectionField] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .connection.additionalConnectionFields ?? []
    }

    // MARK: - Plugin Property Lookups

    func driverPlugin(for databaseType: DatabaseType) -> (any DriverPlugin)? {
        driverPlugins[databaseType.pluginTypeId]
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
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .editorLanguage ?? .sql
    }

    func queryLanguageName(for databaseType: DatabaseType) -> String {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .queryLanguageName ?? "SQL"
    }

    func connectionMode(for databaseType: DatabaseType) -> ConnectionMode {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .connectionMode ?? .network
    }

    func brandColor(for databaseType: DatabaseType) -> Color {
        if let hex = PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?.brandColorHex {
            return Color(hex: hex)
        }
        return Color.gray
    }

    func supportsDatabaseSwitching(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .supportsDatabaseSwitching ?? true
    }

    func supportsSchemaSwitching(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.supportsSchemaSwitching ?? false
    }

    func supportsImport(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.supportsImport ?? true
    }

    func systemDatabaseNames(for databaseType: DatabaseType) -> [String] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.systemDatabaseNames ?? []
    }

    func systemSchemaNames(for databaseType: DatabaseType) -> [String] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.systemSchemaNames ?? []
    }

    func columnTypesByCategory(for databaseType: DatabaseType) -> [String: [String]] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .editor.columnTypesByCategory ?? PluginMetadataSnapshot.EditorConfig.defaults.columnTypesByCategory
    }

    func requiresAuthentication(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .requiresAuthentication ?? true
    }

    func fileExtensions(for databaseType: DatabaseType) -> [String] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.fileExtensions ?? []
    }

    func tableEntityName(for databaseType: DatabaseType) -> String {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.tableEntityName ?? "Tables"
    }

    func supportsCascadeDrop(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.supportsCascadeDrop ?? false
    }

    func supportsForeignKeyDisable(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.supportsForeignKeyDisable ?? true
    }

    func immutableColumns(for databaseType: DatabaseType) -> [String] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.immutableColumns ?? []
    }

    func supportsReadOnlyMode(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.supportsReadOnlyMode ?? true
    }

    func defaultSchemaName(for databaseType: DatabaseType) -> String {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.defaultSchemaName ?? "public"
    }

    func requiresReconnectForDatabaseSwitch(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.requiresReconnectForDatabaseSwitch ?? false
    }

    func structureColumnFields(for databaseType: DatabaseType) -> [StructureColumnField] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.structureColumnFields ?? [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
    }

    func defaultPrimaryKeyColumn(for databaseType: DatabaseType) -> String? {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.defaultPrimaryKeyColumn
    }

    func supportsQueryProgress(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.supportsQueryProgress ?? false
    }

    func supportsSSH(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.supportsSSH ?? true
    }

    func supportsSSL(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.supportsSSL ?? true
    }

    func supportsColumnReorder(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .supportsColumnReorder ?? false
    }

    func supportsDropDatabase(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.supportsDropDatabase ?? false
    }

    func autoLimitStyle(for databaseType: DatabaseType) -> AutoLimitStyle {
        guard let snapshot = PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId) else {
            return .limit
        }
        guard let dialect = snapshot.editor.sqlDialect else { return .none }
        return dialect.autoLimitStyle
    }

    func paginationStyle(for databaseType: DatabaseType) -> SQLDialectDescriptor.PaginationStyle {
        sqlDialect(for: databaseType)?.paginationStyle ?? .limit
    }

    func offsetFetchOrderBy(for databaseType: DatabaseType) -> String {
        sqlDialect(for: databaseType)?.offsetFetchOrderBy ?? "ORDER BY (SELECT NULL)"
    }

    func databaseGroupingStrategy(for databaseType: DatabaseType) -> GroupingStrategy {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.databaseGroupingStrategy ?? .byDatabase
    }

    func defaultGroupName(for databaseType: DatabaseType) -> String {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
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
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let pluginTypeId = databaseType.pluginTypeId

        if let existingEntry = plugins.first(where: { entry in
            entry.databaseTypeId == pluginTypeId || entry.additionalTypeIds.contains(pluginTypeId)
        }) {
            if !existingEntry.isEnabled {
                setEnabled(true, pluginId: existingEntry.id)
                loadPendingPlugins()
            }
            if driverPlugins[pluginTypeId] != nil {
                Self.logger.info("Re-enabled existing plugin '\(existingEntry.name)' for '\(databaseType.rawValue)'")
                return
            }
            Self.logger.warning("Plugin '\(existingEntry.id)' exists but driver not registered, reinstalling")
            if existingEntry.source == .userInstalled {
                do {
                    try uninstallPlugin(id: existingEntry.id)
                } catch {
                    Self.logger.warning("Failed to uninstall plugin '\(existingEntry.id)' before reinstall: \(error.localizedDescription)")
                }
            }
        }

        let registryClient = RegistryClient.shared
        await registryClient.fetchManifest()

        guard let manifest = registryClient.manifest else {
            throw PluginError.downloadFailed(String(localized: "Could not fetch plugin registry"))
        }

        guard let registryPlugin = manifest.plugins.first(where: { plugin in
            plugin.databaseTypeIds?.contains(pluginTypeId) == true
        }) else {
            throw PluginError.notFound
        }

        let entry = try await installFromRegistry(registryPlugin, progress: progress)
        Self.logger.info("Installed missing plugin '\(entry.name)' for database type '\(databaseType.rawValue)'")
    }
}
