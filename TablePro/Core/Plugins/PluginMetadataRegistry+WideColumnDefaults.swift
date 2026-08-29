//
//  PluginMetadataRegistry+WideColumnDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Cassandra, ScyllaDB and etcd, split out of `registryPluginDefaults` so that file stays inside the
/// 1200-line limit. Cassandra and ScyllaDB are one driver behind two type ids, and etcd ships in the
/// same family of non-relational stores.
extension PluginMetadataRegistry {
    // swiftlint:disable:next function_body_length
    func wideColumnPluginDefaults(
        cassandraDialect: SQLDialectDescriptor,
        cassandraColumnTypes: [String: [String]],
        etcdCompletions: [CompletionEntry]
    ) -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [
            ("Cassandra", PluginMetadataSnapshot(
                displayName: "Cassandra / ScyllaDB", iconName: "cassandra-icon", defaultPort: 9_042,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "cassandra", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["cassandra", "cql", "scylladb", "scylla"],
                postConnectActions: [],
                brandColorHex: "#26A0D8",
                queryLanguageName: "CQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
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
                    supportsDropDatabase: true,
                    supportsModifyColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false,
                    supportsOpportunisticTLS: false,
                    supportsClientKeyPassphrase: true
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "default",
                    tableEntityName: "Tables",
                    containerEntityName: "Keyspace",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [
                        "system", "system_schema", "system_auth",
                        "system_distributed", "system_traces", "system_virtual_schema"
                    ],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: cassandraDialect,
                    statementCompletions: [],
                    columnTypesByCategory: cassandraColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "sslCaCertPath",
                            label: "CA Certificate",
                            placeholder: "/path/to/ca-cert.pem",
                            section: .advanced
                        )
                    ],
                    category: .wideColumn,
                    tagline: String(localized: "Distributed wide-column store")
                )
            )),
            ("ScyllaDB", PluginMetadataSnapshot(
                displayName: "ScyllaDB", iconName: "scylladb-icon", defaultPort: 9_042,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "scylladb", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["scylladb", "scylla"],
                postConnectActions: [],
                brandColorHex: "#6B2EE3",
                queryLanguageName: "CQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
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
                    supportsDropDatabase: true,
                    supportsModifyColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false,
                    supportsOpportunisticTLS: false,
                    supportsClientKeyPassphrase: true
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "default",
                    tableEntityName: "Tables",
                    containerEntityName: "Keyspace",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [
                        "system", "system_schema", "system_auth",
                        "system_distributed", "system_traces", "system_virtual_schema"
                    ],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: cassandraDialect,
                    statementCompletions: [],
                    columnTypesByCategory: cassandraColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "sslCaCertPath",
                            label: "CA Certificate",
                            placeholder: "/path/to/ca-cert.pem",
                            section: .advanced
                        )
                    ],
                    category: .wideColumn,
                    tagline: String(localized: "C++ rewrite of Cassandra, faster")
                )
            )),
            ("etcd", PluginMetadataSnapshot(
                displayName: "etcd", iconName: "etcd-icon", defaultPort: 2_379,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "etcd", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["etcd", "etcds"], postConnectActions: [],
                brandColorHex: "#419EDA",
                queryLanguageName: "etcdctl", editorLanguage: .bash,
                connectionMode: .network, supportsDatabaseSwitching: false,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: false,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsOpportunisticTLS: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Keys",
                    containerEntityName: "Database",
                    defaultPrimaryKeyColumn: "Key",
                    immutableColumns: ["Version", "ModRevision", "CreateRevision"],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: etcdCompletions,
                    columnTypesByCategory: ["String": ["string"]]
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "etcdKeyPrefix",
                            label: String(localized: "Key Prefix Root"),
                            placeholder: "/",
                            section: .advanced
                        ),
                        ConnectionField(
                            id: "etcdTlsMode",
                            label: String(localized: "TLS Mode"),
                            fieldType: .dropdown(options: [
                                .init(value: "Disabled", label: "Disabled"),
                                .init(value: "Required", label: String(localized: "Required (skip verify)")),
                                .init(value: "VerifyCA", label: String(localized: "Verify CA")),
                                .init(value: "VerifyIdentity", label: String(localized: "Verify Identity")),
                            ]),
                            section: .advanced
                        ),
                        ConnectionField(
                            id: "etcdCaCertPath",
                            label: String(localized: "CA Certificate"),
                            placeholder: "/path/to/ca.pem",
                            section: .advanced
                        ),
                        ConnectionField(
                            id: "etcdClientCertPath",
                            label: String(localized: "Client Certificate"),
                            placeholder: "/path/to/client.pem",
                            section: .advanced
                        ),
                        ConnectionField(
                            id: "etcdClientKeyPath",
                            label: String(localized: "Client Key"),
                            placeholder: "/path/to/client-key.pem",
                            section: .advanced
                        ),
                    ],
                    category: .coordination,
                    tagline: String(localized: "Distributed key-value store for service discovery"),
                    hidesBuiltInDatabase: true
                )
            )),
        ]
    }
}
