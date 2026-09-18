//
//  PluginMetadataRegistry+KafkaDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    /// The curated snapshot for Kafka.
    ///
    /// A registry-only driver is not installed until someone connects with it, so without an
    /// entry here the type is absent from the New Connection picker and there is no way to
    /// create the connection that would trigger the install. The connection fields are
    /// duplicated from `KafkaConnectionField` for the same reason: the plugin that owns them
    /// is not loaded yet.
    func kafkaPluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("Kafka", PluginMetadataSnapshot(
                displayName: "Kafka", iconName: "kafka-icon", defaultPort: 9_092,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "kafka", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [],
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["kafka"],
                postConnectActions: [],
                brandColorHex: "#231F20",
                queryLanguageName: "KafkaQL", editorLanguage: .custom("kafkaql"),
                connectionMode: .network, supportsDatabaseSwitching: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsDropSchema: false,
                    defaultSSLMode: .verifyIdentity,
                    supportsOpportunisticTLS: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "",
                    defaultGroupName: "cluster",
                    tableEntityName: "Topics",
                    containerEntityName: "Cluster",
                    schemaEntityName: "Schema",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [.name, .type, .nullable]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: kafkaCompletions,
                    columnTypesByCategory: kafkaColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: kafkaConnectionFields(),
                    category: .streaming,
                    tagline: String(localized: "Event streaming platform")
                )
            )),
        ]
    }
}

private let kafkaCompletions: [CompletionEntry] = [
    CompletionEntry(label: "CONSUME", insertText: "CONSUME \"topic\" FROM NEWEST LIMIT 100"),
    CompletionEntry(label: "CONSUME FROM OLDEST", insertText: "CONSUME \"topic\" FROM OLDEST LIMIT 100"),
    CompletionEntry(label: "CONSUME FROM OFFSET", insertText: "CONSUME \"topic\" FROM OFFSET 0 LIMIT 100"),
    CompletionEntry(label: "PRODUCE", insertText: "PRODUCE INTO \"topic\" KEY \"k\" VALUE \"v\""),
    CompletionEntry(label: "SHOW TOPICS", insertText: "SHOW TOPICS"),
    CompletionEntry(label: "SHOW GROUPS", insertText: "SHOW GROUPS"),
    CompletionEntry(label: "DESCRIBE GROUP", insertText: "DESCRIBE GROUP \"group\""),
    CompletionEntry(label: "DESCRIBE TOPIC", insertText: "DESCRIBE TOPIC \"topic\"")
]

private let kafkaColumnTypes: [String: [String]] = [
    "Message": ["TEXT", "BLOB", "JSON"],
    "Coordinates": ["INTEGER", "BIGINT", "TIMESTAMP"]
]

/// Kept identical to `KafkaConnectionField.fields()` in the plugin. The two cannot share code:
/// this list has to exist before the bundle that owns it is downloaded.
private func kafkaConnectionFields() -> [ConnectionField] {
    [
        ConnectionField(
            id: "kafkaBootstrapServers",
            label: String(localized: "Additional Bootstrap Servers"),
            placeholder: "broker-2:9092",
            required: false,
            fieldType: .hostList,
            section: .connection
        ),
        ConnectionField(
            id: "kafkaSecurityProtocol",
            label: String(localized: "Security Protocol"),
            required: true,
            defaultValue: "PLAINTEXT",
            fieldType: .dropdown(options: [
                .init(value: "PLAINTEXT", label: "PLAINTEXT"),
                .init(value: "SSL", label: "SSL"),
                .init(value: "SASL_PLAINTEXT", label: "SASL_PLAINTEXT"),
                .init(value: "SASL_SSL", label: "SASL_SSL")
            ]),
            section: .connection
        ),
        ConnectionField(
            id: "kafkaSaslMechanism",
            label: String(localized: "SASL Mechanism"),
            required: true,
            defaultValue: "PLAIN",
            fieldType: .dropdown(options: [
                .init(value: "PLAIN", label: "PLAIN"),
                .init(value: "SCRAM-SHA-256", label: "SCRAM-SHA-256"),
                .init(value: "SCRAM-SHA-512", label: "SCRAM-SHA-512")
            ]),
            section: .authentication,
            visibleWhen: FieldVisibilityRule(
                fieldId: "kafkaSecurityProtocol",
                values: ["SASL_PLAINTEXT", "SASL_SSL"]
            )
        ),
        ConnectionField(
            id: "kafkaBrokerRouting",
            label: String(localized: "Broker Addresses"),
            required: false,
            defaultValue: "advertised",
            fieldType: .dropdown(options: [
                .init(value: "advertised", label: String(localized: "Use the addresses the cluster advertises")),
                .init(value: "bootstrapOnly", label: String(localized: "Only use the bootstrap address"))
            ]),
            section: .advanced
        ),
        ConnectionField(
            id: "kafkaConnectTimeout",
            label: String(localized: "Connect Timeout (seconds)"),
            required: false,
            defaultValue: "10",
            fieldType: .stepper(range: ConnectionField.IntRange(1 ... 120)),
            section: .advanced
        )
    ]
}
