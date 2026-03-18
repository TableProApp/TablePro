//
//  EtcdPlugin.swift
//  EtcdDriverPlugin
//
//  etcd v3 database driver plugin via HTTP/JSON gateway
//

import Foundation
import os
import TableProPluginKit

final class EtcdPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "etcd Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "etcd v3 support via HTTP/JSON gateway"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "etcd"
    static let databaseDisplayName = "etcd"
    static let iconName = "etcd-icon"
    static let defaultPort = 2379
    static let additionalDatabaseTypeIds: [String] = []
    static let isDownloadable = true

    static let navigationModel: NavigationModel = .standard
    static let pathFieldRole: PathFieldRole = .database
    static let requiresAuthentication = false
    static let urlSchemes: [String] = ["etcd", "etcds"]
    static let brandColorHex = "#419EDA"
    static let queryLanguageName = "etcdctl"
    static let editorLanguage: EditorLanguage = .bash
    static let supportsForeignKeys = false
    static let supportsSchemaEditing = false
    static let supportsDatabaseSwitching = false
    static let supportsImport = false
    static let tableEntityName = "Keys"
    static let supportsForeignKeyDisable = false
    static let supportsReadOnlyMode = false
    static let databaseGroupingStrategy: GroupingStrategy = .flat
    static let defaultGroupName = "main"
    static let defaultPrimaryKeyColumn: String? = "Key"
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable]
    static let sqlDialect: SQLDialectDescriptor? = nil
    static let columnTypesByCategory: [String: [String]] = ["String": ["string"]]

    static let additionalConnectionFields: [ConnectionField] = [
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
    ]

    static var statementCompletions: [CompletionEntry] {
        [
            CompletionEntry(label: "get", insertText: "get"),
            CompletionEntry(label: "put", insertText: "put"),
            CompletionEntry(label: "del", insertText: "del"),
            CompletionEntry(label: "watch", insertText: "watch"),
            CompletionEntry(label: "lease grant", insertText: "lease grant"),
            CompletionEntry(label: "lease revoke", insertText: "lease revoke"),
            CompletionEntry(label: "lease timetolive", insertText: "lease timetolive"),
            CompletionEntry(label: "lease list", insertText: "lease list"),
            CompletionEntry(label: "lease keep-alive", insertText: "lease keep-alive"),
            CompletionEntry(label: "member list", insertText: "member list"),
            CompletionEntry(label: "endpoint status", insertText: "endpoint status"),
            CompletionEntry(label: "endpoint health", insertText: "endpoint health"),
            CompletionEntry(label: "compaction", insertText: "compaction"),
            CompletionEntry(label: "auth enable", insertText: "auth enable"),
            CompletionEntry(label: "auth disable", insertText: "auth disable"),
            CompletionEntry(label: "user add", insertText: "user add"),
            CompletionEntry(label: "user delete", insertText: "user delete"),
            CompletionEntry(label: "user list", insertText: "user list"),
            CompletionEntry(label: "role add", insertText: "role add"),
            CompletionEntry(label: "role delete", insertText: "role delete"),
            CompletionEntry(label: "role list", insertText: "role list"),
            CompletionEntry(label: "user grant-role", insertText: "user grant-role"),
            CompletionEntry(label: "user revoke-role", insertText: "user revoke-role"),
            CompletionEntry(label: "--prefix", insertText: "--prefix"),
            CompletionEntry(label: "--limit", insertText: "--limit="),
            CompletionEntry(label: "--keys-only", insertText: "--keys-only"),
            CompletionEntry(label: "--lease", insertText: "--lease="),
        ]
    }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        EtcdPluginDriver(config: config)
    }
}
