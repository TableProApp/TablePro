//
//  DynamoDBPlugin.swift
//  DynamoDBDriverPlugin
//
//  Amazon DynamoDB driver plugin via AWS HTTP API with PartiQL support
//

import Foundation
import os
import TableProPluginKit

final class DynamoDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "DynamoDB Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Amazon DynamoDB support via AWS HTTP API with PartiQL"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "DynamoDB"
    static let databaseDisplayName = "Amazon DynamoDB"
    static let iconName = "dynamodb-icon"
    static let defaultPort = 0
    static let additionalDatabaseTypeIds: [String] = []
    static let isDownloadable = true

    static let connectionMode: ConnectionMode = .apiOnly
    static let navigationModel: NavigationModel = .standard
    static let pathFieldRole: PathFieldRole = .database
    static let requiresAuthentication = true
    static let urlSchemes: [String] = []
    static let brandColorHex = "#4053D6"
    static let queryLanguageName = "PartiQL"
    static let editorLanguage: EditorLanguage = .sql
    static let supportsForeignKeys = false
    static let supportsSchemaEditing = false
    static let supportsDatabaseSwitching = false
    static let supportsImport = false
    static let supportsExport = true
    static let supportsSSH = false
    static let supportsSSL = false
    static let tableEntityName = "Tables"
    static let supportsForeignKeyDisable = false
    static let supportsReadOnlyMode = true
    static let databaseGroupingStrategy: GroupingStrategy = .flat
    static let defaultGroupName = "main"
    static let defaultPrimaryKeyColumn: String? = nil
    static let structureColumnFields: [StructureColumnField] = [.name, .type]

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: [
            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUE", "SET",
            "UPDATE", "DELETE", "AND", "OR", "NOT", "IN", "BETWEEN",
            "EXISTS", "MISSING", "IS", "NULL", "LIMIT"
        ],
        functions: [
            "begins_with", "contains", "size", "attribute_type",
            "attribute_exists", "attribute_not_exists"
        ],
        dataTypes: ["S", "N", "B", "BOOL", "NULL", "L", "M", "SS", "NS", "BS"]
    )

    static let columnTypesByCategory: [String: [String]] = [
        "String": ["S"],
        "Number": ["N"],
        "Binary": ["B"],
        "Boolean": ["BOOL"],
        "Null": ["NULL"],
        "List": ["L"],
        "Map": ["M"],
        "String Set": ["SS"],
        "Number Set": ["NS"],
        "Binary Set": ["BS"]
    ]

    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(
            id: "awsAuthMethod",
            label: String(localized: "Auth Method"),
            defaultValue: "credentials",
            fieldType: .dropdown(options: [
                .init(value: "credentials", label: "Access Key + Secret Key"),
                .init(value: "profile", label: "AWS Profile"),
                .init(value: "sso", label: "AWS SSO")
            ]),
            section: .authentication
        ),
        ConnectionField(
            id: "awsAccessKeyId",
            label: String(localized: "Access Key ID"),
            placeholder: "AKIA...",
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "awsAuthMethod", values: ["credentials"])
        ),
        ConnectionField(
            id: "awsSecretAccessKey",
            label: String(localized: "Secret Access Key"),
            placeholder: "wJalr...",
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true,
            visibleWhen: FieldVisibilityRule(fieldId: "awsAuthMethod", values: ["credentials"])
        ),
        ConnectionField(
            id: "awsSessionToken",
            label: String(localized: "Session Token"),
            placeholder: "Optional (for temporary credentials)",
            fieldType: .secure,
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "awsAuthMethod", values: ["credentials"])
        ),
        ConnectionField(
            id: "awsProfileName",
            label: String(localized: "Profile Name"),
            placeholder: "default",
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "awsAuthMethod", values: ["profile", "sso"])
        ),
        ConnectionField(
            id: "awsRegion",
            label: String(localized: "AWS Region"),
            placeholder: "us-east-1",
            defaultValue: "us-east-1",
            fieldType: .text,
            section: .authentication
        ),
        ConnectionField(
            id: "awsEndpointUrl",
            label: String(localized: "Custom Endpoint"),
            placeholder: "http://localhost:8000 (DynamoDB Local)",
            section: .authentication
        ),
    ]

    static var statementCompletions: [CompletionEntry] {
        [
            CompletionEntry(label: "SELECT", insertText: "SELECT"),
            CompletionEntry(label: "INSERT INTO", insertText: "INSERT INTO"),
            CompletionEntry(label: "UPDATE", insertText: "UPDATE"),
            CompletionEntry(label: "DELETE FROM", insertText: "DELETE FROM"),
            CompletionEntry(label: "VALUE", insertText: "VALUE"),
            CompletionEntry(label: "SET", insertText: "SET"),
            CompletionEntry(label: "WHERE", insertText: "WHERE"),
            CompletionEntry(label: "AND", insertText: "AND"),
            CompletionEntry(label: "OR", insertText: "OR"),
            CompletionEntry(label: "BETWEEN", insertText: "BETWEEN"),
            CompletionEntry(label: "EXISTS", insertText: "EXISTS"),
            CompletionEntry(label: "MISSING", insertText: "MISSING"),
            CompletionEntry(label: "IN", insertText: "IN"),
            CompletionEntry(label: "IS", insertText: "IS"),
            CompletionEntry(label: "NOT", insertText: "NOT"),
            CompletionEntry(label: "NULL", insertText: "NULL"),
            CompletionEntry(label: "begins_with", insertText: "begins_with"),
            CompletionEntry(label: "contains", insertText: "contains"),
            CompletionEntry(label: "size", insertText: "size"),
            CompletionEntry(label: "attribute_type", insertText: "attribute_type"),
            CompletionEntry(label: "attribute_exists", insertText: "attribute_exists"),
            CompletionEntry(label: "attribute_not_exists", insertText: "attribute_not_exists")
        ]
    }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        DynamoDBPluginDriver(config: config)
    }
}
