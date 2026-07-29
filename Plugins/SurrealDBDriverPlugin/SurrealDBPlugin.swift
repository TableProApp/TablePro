//
//  SurrealDBPlugin.swift
//  SurrealDBDriverPlugin
//

import Foundation
import TableProPluginKit

final class SurrealDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "SurrealDB Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "SurrealDB driver over the HTTP RPC protocol with SurrealQL"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "SurrealDB"
    static let databaseDisplayName = "SurrealDB"
    static let iconName = "surrealdb-icon"
    static let defaultPort = 8000

    static let connectionMode: ConnectionMode = .network
    static let isDownloadable = true
    static let supportsSSH = true
    static let supportsSSL = true
    static let supportsImport = false
    static let supportsSchemaEditing = false
    static let supportsForeignKeys = false
    static let supportsTriggers = false
    static let supportsTriggerEditing = false
    static let brandColorHex = "#FF00A0"
    static let urlSchemes: [String] = ["surrealdb"]
    static let queryLanguageName = "SurrealQL"
    static let editorLanguage: EditorLanguage = .custom("surrealql")
    static let parameterStyle: ParameterStyle = .dollar

    static let supportsDatabaseSwitching = true
    static let supportsSchemaSwitching = true
    static let databaseGroupingStrategy: GroupingStrategy = .bySchema
    static let containerEntityName = "Namespace"
    static let schemaEntityName = "Database"
    static let defaultSchemaName = ""
    static let defaultPrimaryKeyColumn: String? = "id"
    static let immutableColumns: [String] = ["id"]
    static let supportsDropDatabase = true
    static let postConnectActions: [PostConnectAction] = [.selectSchemaFromLastSession]

    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable]

    static let explainVariants: [ExplainVariant] = [
        ExplainVariant(id: "explain", label: "Explain", sqlPrefix: "EXPLAIN"),
        ExplainVariant(id: "explainFull", label: "Explain Full", sqlPrefix: "EXPLAIN FULL")
    ]

    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["int"],
        "Float": ["float", "decimal", "number"],
        "String": ["string", "uuid"],
        "Date": ["datetime", "duration"],
        "Binary": ["bytes"],
        "Boolean": ["bool"],
        "Structured": ["object", "array", "set", "geometry", "record", "any"]
    ]

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "`",
        keywords: [
            "SELECT", "FROM", "WHERE", "ORDER", "BY", "GROUP", "ALL", "LIMIT", "START", "FETCH",
            "SPLIT", "OMIT", "ONLY", "PARALLEL", "TIMEOUT", "EXPLAIN", "WITH", "INDEX",
            "CREATE", "UPDATE", "UPSERT", "DELETE", "INSERT", "RELATE", "CONTENT", "MERGE",
            "PATCH", "SET", "RETURN", "BEFORE", "AFTER", "DIFF", "NONE", "NULL", "TRUE", "FALSE",
            "DEFINE", "REMOVE", "ALTER", "TABLE", "FIELD", "EVENT", "PARAM", "FUNCTION",
            "NAMESPACE", "DATABASE", "USER", "ACCESS", "ANALYZER", "SCOPE", "TOKEN",
            "SCHEMAFULL", "SCHEMALESS", "PERMISSIONS", "TYPE", "ASSERT", "DEFAULT", "VALUE",
            "READONLY", "FLEXIBLE", "UNIQUE", "SEARCH", "MTREE", "HNSW", "COUNT",
            "USE", "NS", "DB", "LET", "IF", "ELSE", "THEN", "END", "FOR", "IN", "CONTINUE", "BREAK",
            "BEGIN", "COMMIT", "CANCEL", "TRANSACTION", "INFO", "LIVE", "KILL",
            "AND", "OR", "NOT", "IS", "CONTAINS", "CONTAINSNOT", "INSIDE", "NOTINSIDE",
            "OUTSIDE", "INTERSECTS", "ASC", "DESC", "AS", "ON", "IF NOT EXISTS"
        ],
        functions: [
            "count", "math::sum", "math::mean", "math::min", "math::max", "math::abs",
            "string::concat", "string::contains", "string::starts_with", "string::ends_with",
            "string::len", "string::lowercase", "string::uppercase", "string::trim",
            "string::split", "string::join", "string::replace", "string::slice",
            "time::now", "time::floor", "time::group", "time::unix", "time::format",
            "array::len", "array::distinct", "array::flatten", "array::group", "array::sort",
            "array::append", "array::concat", "array::union", "array::first", "array::last",
            "type::is_number", "type::is_string", "type::table", "type::field", "type::thing",
            "rand::uuid", "rand::int", "rand::float", "object::keys", "object::values",
            "meta::id", "meta::tb", "record::id", "record::table"
        ],
        dataTypes: [
            "any", "array", "bool", "bytes", "datetime", "decimal", "duration", "float",
            "geometry", "int", "number", "object", "option", "record", "set", "string", "uuid"
        ],
        regexSyntax: .unsupported,
        booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit,
        paginationStyle: .limit,
        autoLimitStyle: .limit
    )

    static let additionalConnectionFields: [ConnectionField] = surrealDBPluginConnectionFields()

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        SurrealDBPluginDriver(config: config)
    }
}
