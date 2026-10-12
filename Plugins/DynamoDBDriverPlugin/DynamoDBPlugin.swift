import Foundation
import os
import TableProPluginKit

final class DynamoDBPlugin: NSObject, TableProPlugin, DriverPlugin, PluginDefaultSortProvider {
    static let pluginName = "DynamoDB Driver"
    static let pluginVersion = "2.0.0"
    static let pluginDescription = "Amazon DynamoDB: tables, indexes, PartiQL and the DynamoDB API"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "DynamoDB"
    static let databaseDisplayName = "Amazon DynamoDB"
    static let iconName = "dynamodb-icon"
    static let defaultPort = 0
    static let isDownloadable = true

    static let connectionMode: ConnectionMode = .apiOnly
    static let navigationModel: NavigationModel = .standard
    static let pathFieldRole: PathFieldRole = .database
    static let requiresAuthentication = true
    static let urlSchemes: [String] = []
    static let brandColorHex = "#4053D6"
    static let queryLanguageName = "PartiQL"
    static let editorLanguage: EditorLanguage = .sql
    static let parameterStyle: ParameterStyle = .questionMark
    static let supportsForeignKeys = false
    static let supportsSchemaEditing = true
    static let supportsAddColumn = false
    static let supportsModifyColumn = false
    static let supportsDropColumn = false
    static let supportsRenameColumn = false
    static let supportsModifyPrimaryKey = false
    static let supportsAddIndex = true
    static let supportsDropIndex = true
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
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .primaryKey]
    static let caseSensitivityStyle: SQLDialectDescriptor.CaseSensitivityStyle = .driverManaged

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: DynamoDBEditorVocabulary.keywords,
        functions: DynamoDBEditorVocabulary.functions,
        dataTypes: Set(DynamoDBAttributeType.allCases.map(\.displayName)),
        booleanLiteralStyle: .truefalse,
        autoLimitStyle: .none,
        caseSensitivityStyle: .driverManaged
    )

    static let columnTypesByCategory: [String: [String]] = [
        "Key": [
            DynamoDBAttributeType.string.displayName,
            DynamoDBAttributeType.number.displayName,
            DynamoDBAttributeType.binary.displayName
        ],
        "Scalar": [
            DynamoDBAttributeType.boolean.displayName,
            DynamoDBAttributeType.null.displayName
        ],
        "Document": [
            DynamoDBAttributeType.list.displayName,
            DynamoDBAttributeType.map.displayName
        ],
        "Set": [
            DynamoDBAttributeType.stringSet.displayName,
            DynamoDBAttributeType.numberSet.displayName,
            DynamoDBAttributeType.binarySet.displayName
        ]
    ]

    static var additionalConnectionFields: [ConnectionField] {
        DynamoDBConnectionFields.all
    }

    static var statementCompletions: [CompletionEntry] {
        DynamoDBEditorVocabulary.completions
    }

    func defaultSortHint(forTable table: String) -> DefaultSortHint {
        .suppress
    }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        DynamoDBPluginDriver(config: config)
    }
}

enum DynamoDBConnectionFields {
    static var all: [ConnectionField] {
        [
            ConnectionField(
                id: "awsAuthMethod",
                label: String(localized: "Auth Method"),
                defaultValue: DynamoDBAuthMethod.accessKey.rawValue,
                fieldType: .dropdown(options: [
                    .init(value: DynamoDBAuthMethod.accessKey.rawValue, label: String(localized: "Access Key + Secret Key")),
                    .init(value: DynamoDBAuthMethod.profile.rawValue, label: String(localized: "AWS Profile")),
                    .init(value: DynamoDBAuthMethod.singleSignOn.rawValue, label: String(localized: "AWS SSO")),
                    .init(value: DynamoDBAuthMethod.local.rawValue, label: String(localized: "DynamoDB Local (no credentials)"))
                ]),
                section: .authentication
            ),
            ConnectionField(
                id: "awsAccessKeyId",
                label: String(localized: "Access Key ID"),
                placeholder: "AKIA...",
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: "awsAuthMethod", values: [DynamoDBAuthMethod.accessKey.rawValue])
            ),
            ConnectionField(
                id: "awsSecretAccessKey",
                label: String(localized: "Secret Access Key"),
                placeholder: "wJalr...",
                fieldType: .secure,
                section: .authentication,
                hidesPassword: true,
                visibleWhen: FieldVisibilityRule(fieldId: "awsAuthMethod", values: [DynamoDBAuthMethod.accessKey.rawValue])
            ),
            ConnectionField(
                id: "awsSessionToken",
                label: String(localized: "Session Token"),
                placeholder: String(localized: "Optional, for temporary credentials"),
                fieldType: .secure,
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: "awsAuthMethod", values: [DynamoDBAuthMethod.accessKey.rawValue])
            ),
            ConnectionField(
                id: "awsProfileName",
                label: String(localized: "Profile Name"),
                placeholder: "default",
                section: .authentication,
                visibleWhen: FieldVisibilityRule(
                    fieldId: "awsAuthMethod",
                    values: [DynamoDBAuthMethod.profile.rawValue, DynamoDBAuthMethod.singleSignOn.rawValue]
                )
            ).withDynamicOptions(.awsProfiles),
            ConnectionField(
                id: "awsRegion",
                label: String(localized: "AWS Region"),
                placeholder: String(localized: "The profile's region, or us-east-1"),
                fieldType: .text,
                section: .authentication
            ),
            ConnectionField(
                id: "awsEndpointUrl",
                label: String(localized: "Custom Endpoint"),
                placeholder: String(localized: "Optional, such as http://localhost:8000"),
                section: .authentication
            )
        ]
    }
}

enum DynamoDBEditorVocabulary {
    static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUE", "SET", "REMOVE", "UPDATE", "DELETE",
        "AND", "OR", "NOT", "IN", "BETWEEN", "EXISTS", "MISSING", "IS", "NULL", "TRUE", "FALSE",
        "ORDER", "BY", "ASC", "DESC", "RETURNING", "ALL", "OLD", "NEW", "MODIFIED"
    ]

    static let functions: Set<String> = [
        "begins_with", "contains", "size", "attribute_type", "attribute_exists", "attribute_not_exists", "EXISTS"
    ]

    static var completions: [CompletionEntry] {
        let partiQL = [
            "SELECT", "INSERT INTO", "UPDATE", "DELETE FROM", "VALUE", "SET", "REMOVE", "WHERE", "AND", "OR",
            "BETWEEN", "IN", "IS", "NOT", "NULL", "MISSING", "EXISTS", "ORDER BY", "RETURNING ALL OLD *",
            "begins_with", "contains", "size", "attribute_type"
        ].map { CompletionEntry(label: $0, insertText: $0) }
        let requests: [CompletionEntry] = [
            template("Scan", #"{"TableName": ""}"#),
            template("Query", ##"{"TableName": "", "KeyConditionExpression": "#pk = :pk", "##,
                     ##""ExpressionAttributeNames": {"#pk": ""}, "ExpressionAttributeValues": {":pk": {"S": ""}}}"##),
            template("GetItem", #"{"TableName": "", "Key": {"": {"S": ""}}}"#),
            template("PutItem", #"{"TableName": "", "Item": {"": {"S": ""}}}"#),
            template("UpdateItem", #"{"TableName": "", "Key": {"": {"S": ""}}, "UpdateExpression": ""}"#),
            template("DeleteItem", #"{"TableName": "", "Key": {"": {"S": ""}}}"#),
            template("DescribeTable", #"{"TableName": ""}"#),
            template("CreateTable", #"{"TableName": "", "BillingMode": "PAY_PER_REQUEST", "#,
                     #""AttributeDefinitions": [{"AttributeName": "pk", "AttributeType": "S"}], "#,
                     #""KeySchema": [{"AttributeName": "pk", "KeyType": "HASH"}]}"#),
            template("UpdateTable", #"{"TableName": ""}"#),
            template("UpdateTimeToLive", #"{"TableName": "", "TimeToLiveSpecification": "#,
                     #"{"Enabled": true, "AttributeName": "expiresAt"}}"#)
        ]
        return partiQL + requests
    }

    private static func template(_ operation: String, _ parts: String...) -> CompletionEntry {
        CompletionEntry(label: "\(operation) {…}", insertText: "\(operation) " + parts.joined())
    }
}
