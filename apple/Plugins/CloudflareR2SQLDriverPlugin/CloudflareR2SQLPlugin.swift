//
//  CloudflareR2SQLPlugin.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class CloudflareR2SQLPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Cloudflare R2 SQL Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Read-only Cloudflare R2 SQL driver for Apache Iceberg tables in R2"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Cloudflare R2 SQL"
    static let databaseDisplayName = CloudflareR2SQLMetadata.displayName
    static let iconName = CloudflareR2SQLMetadata.iconName
    static let defaultPort = 0

    static let connectionMode: ConnectionMode = .apiOnly
    static let supportsSSH = false
    static let supportsSSL = false
    static let isDownloadable = true
    static let supportsImport = false
    static let supportsExport = true
    static let supportsSchemaEditing = false
    static let supportsForeignKeys = false
    static let supportsDropDatabase = false
    static let supportsCascadeDrop = false
    static let supportsForeignKeyDisable = false
    static let supportsAddColumn = false
    static let supportsModifyColumn = false
    static let supportsDropColumn = false
    static let supportsAddIndex = false
    static let supportsDropIndex = false
    static let supportsModifyPrimaryKey = false
    static let supportsDatabaseSwitching = false
    static let supportsSchemaSwitching = true
    static let supportsHealthMonitor = false
    static let supportsQueryProgress = false
    static let databaseGroupingStrategy: GroupingStrategy = .hierarchicalSchema
    static let defaultSchemaName = CloudflareR2SQLMetadata.defaultSchemaName
    static let schemaEntityName = CloudflareR2SQLMetadata.schemaEntityName
    static let containerEntityName = CloudflareR2SQLMetadata.containerEntityName
    static let brandColorHex = CloudflareR2SQLMetadata.brandColorHex
    static let postConnectActions: [PostConnectAction] = [.selectSchemaFromLastSession]
    static let explainVariants = CloudflareR2SQLMetadata.explainVariants
    static let structureColumnFields = CloudflareR2SQLMetadata.structureColumnFields
    static let columnTypesByCategory = CloudflareR2SQLMetadata.columnTypesByCategory
    static let statementCompletions = CloudflareR2SQLMetadata.statementCompletions
    static let sqlDialect: SQLDialectDescriptor? = CloudflareR2SQLMetadata.dialect
    static let additionalConnectionFields = CloudflareR2SQLMetadata.connectionFields

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        CloudflareR2SQLPluginDriver(config: config)
    }
}
