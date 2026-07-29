//
//  BeancountPlugin.swift
//  BeancountDriverPlugin
//

import Foundation
import TableProPluginKit

final class BeancountPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Beancount Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Read-only Beancount ledger support"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Beancount"
    static let databaseDisplayName = "Beancount"
    static let iconName = "beancount-icon"
    static let defaultPort = 0

    static let isDownloadable = true
    static let pathFieldRole: PathFieldRole = .filePath
    static let requiresAuthentication = false
    static let supportsSSH = false
    static let supportsSSL = false
    static let connectionMode: ConnectionMode = .fileBased
    static let urlSchemes: [String] = ["beancount"]
    static let fileExtensions: [String] = ["beancount"]
    static let brandColorHex = "#3F7D20"
    static let supportsForeignKeys = false
    static let supportsSchemaEditing = false
    static let supportsDatabaseSwitching = false
    static let supportsSchemaSwitching = false
    static let supportsImport = false
    static let supportsHealthMonitor = false
    static let databaseGroupingStrategy: GroupingStrategy = .flat
    static let tableEntityName = "Ledger Tables"
    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["INTEGER"],
        "String": ["TEXT"],
        "Date": ["DATE"]
    ]
    static let immutableColumns: [String] = [
        "id", "transaction_id", "date", "flag", "payee", "narration",
        "account", "amount", "commodity", "cost_number", "cost_currency",
        "currency", "currencies", "name", "open_date", "path"
    ]

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER",
            "ON", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "AS",
            "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET",
            "WITH", "RECURSIVE", "UNION", "INTERSECT", "EXCEPT",
            "CASE", "WHEN", "THEN", "ELSE", "END", "NULL", "IS",
            "ASC", "DESC", "DISTINCT"
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN",
            "COALESCE", "NULLIF", "ROUND", "ABS",
            "DATE", "STRFTIME", "SUBSTR", "LOWER", "UPPER"
        ],
        dataTypes: ["INTEGER", "TEXT", "DATE"],
        regexSyntax: .unsupported,
        booleanLiteralStyle: .numeric,
        likeEscapeStyle: .explicit,
        paginationStyle: .limit
    )

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        BeancountPluginDriver(config: config)
    }
}
