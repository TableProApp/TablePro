//
//  DatabaseType+Registry.swift
//  TablePro
//

import AppKit
import Foundation
import SwiftUI
import TableProPluginKit

/// Everything a `DatabaseType` knows by asking the plugin registry.
///
/// It lives apart from the type itself because these are the members that make naming a database
/// type cost the whole plugin system at compile time. `DatabaseType` is a string a connection
/// carries and a value the display layer compares against a constant; keeping the lookups here
/// means a file that only does that does not compile against the registry, the snapshot table and
/// the theme engine behind them.

extension DatabaseType {
    /// All registered database types, derived dynamically from the plugin metadata registry.
    static var allKnownTypes: [DatabaseType] {
        PluginMetadataRegistry.shared.allRegisteredTypeIds().map { DatabaseType(rawValue: $0) }
    }
}

extension DatabaseType {
    /// Returns nil if rawValue doesn't match any registered type.
    init?(validating rawValue: String) {
        guard PluginMetadataRegistry.shared.hasType(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

extension DatabaseType {
    /// Plugin type ID used for PluginManager lookup, resolved via the registry.
    var pluginTypeId: String {
        PluginMetadataRegistry.shared.pluginTypeId(for: rawValue)
    }

    /// Genuinely a fact about the plugin binary rather than the database, so it asks by
    /// `pluginTypeId`: Redshift is served by the bundled PostgreSQL plugin and there is nothing
    /// of its own to download.
    var isDownloadablePlugin: Bool {
        PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: pluginTypeId)?.isDownloadable ?? false
    }

    var iconName: String {
        PluginMetadataRegistry.shared.snapshot(for: self)?.iconName ?? "database-icon"
    }

    /// Returns the correct SwiftUI Image for this database type, handling both
    /// SF Symbol names (e.g. "cylinder.fill") and asset catalog names (e.g. "mysql-icon").
    var iconImage: Image {
        let name = iconName
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return Image(systemName: name)
        }
        return Image(name).resizable()
    }

    var defaultPort: Int {
        PluginMetadataRegistry.shared.snapshot(for: self)?.defaultPort ?? 0
    }

    var defaultSSLMode: SSLMode {
        PluginMetadataRegistry.shared.snapshot(for: self)?.capabilities.defaultSSLMode ?? .disabled
    }

    var supportsOpportunisticTLS: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.capabilities.supportsOpportunisticTLS ?? true
    }

    var supportsClientKeyPassphrase: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.capabilities.supportsClientKeyPassphrase ?? false
    }

    var supportsConnectionPooling: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.capabilities.supportsConnectionPooling ?? true
    }

    var authenticationIsDatabaseScoped: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?
            .capabilities.authenticationIsDatabaseScoped ?? false
    }

    var defaultHost: String? {
        PluginMetadataRegistry.shared.snapshot(for: self)?.connection.defaultHost
    }

    var supportsCloudSQLProxy: Bool {
        switch rawValue {
        case "MySQL", "PostgreSQL", "SQL Server":
            return true
        default:
            return false
        }
    }

    var sslPaneTooltip: String {
        switch rawValue {
        case "PostgreSQL", "Redshift", "CockroachDB":
            return String(localized: """
                Preferred tries TLS first, falls back to plain. Matches psql and DataGrip defaults. \
                Required by AWS RDS, Cloud SQL, Heroku, Supabase, Neon.
                """)
        case "MySQL", "MariaDB":
            return String(localized: """
                Preferred performs a 2-pass connect: tries TLS first, falls back to plain only on \
                SSL handshake errors. Required by Cloud SQL and Azure MySQL.
                """)
        case "SQL Server":
            return String(localized: "Preferred requests TLS; the server decides. Required by SQL Server 2022 and Azure SQL Database.")
        case "MongoDB":
            return String(localized: "MongoDB driver has no TLS fallback. Preferred and Required both force TLS. Use Required for MongoDB Atlas and other hosted instances.")
        case "Redis":
            return String(localized: """
                Redis driver has no TLS fallback. Preferred and Required both force TLS. \
                Use Required for Redis Cloud, Upstash, and AWS ElastiCache encrypted endpoints.
                """)
        case "Oracle":
            return String(localized: "OracleNIO has no TLS fallback. Preferred connects in plain TCP. Use Required for TCPS to Oracle Autonomous Database.")
        case "Cassandra", "ScyllaDB":
            return String(localized: "Use Required for AstraDB, DataStax Astra, and other hosted Cassandra deployments.")
        case "ClickHouse":
            return String(localized: "Use Required for ClickHouse Cloud and other managed instances.")
        default:
            return ""
        }
    }

    var explainVariants: [ExplainVariant] {
        PluginMetadataRegistry.shared.snapshot(for: self)?.explainVariants ?? []
    }

    var category: DatabaseCategory {
        PluginMetadataRegistry.shared.snapshot(for: self)?.connection.category ?? .other
    }

    var pathFieldRole: PathFieldRole {
        PluginMetadataRegistry.shared.snapshot(for: self)?.pathFieldRole ?? .database
    }

    var tagline: String? {
        let raw = PluginMetadataRegistry.shared.snapshot(for: self)?.connection.tagline ?? ""
        return raw.isEmpty ? nil : raw
    }

    var requiresAuthentication: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.requiresAuthentication ?? true
    }

    var supportsForeignKeys: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.supportsForeignKeys ?? true
    }

    var supportsTriggers: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.capabilities.supportsTriggers ?? false
    }

    var supportsTriggerEditing: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.capabilities.supportsTriggerEditing ?? false
    }

    var supportsCheckConstraints: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.capabilities.supportsCheckConstraints ?? false
    }

    var supportsCheckConstraintEditing: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.capabilities.supportsCheckConstraintEditing ?? false
    }

    var supportsGeneratedColumns: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.capabilities.supportsGeneratedColumns ?? false
    }

    var supportsRoutines: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.capabilities.supportsRoutines ?? false
    }

    var supportsDatabaseTriggerBrowse: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?
            .capabilities.supportsDatabaseTriggerBrowse ?? false
    }

    var supportsUserDefinedTypeBrowse: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?
            .capabilities.supportsUserDefinedTypeBrowse ?? false
    }

    /// The object kinds the sidebar should offer a section for even before any have been fetched.
    /// It never subtracts: a kind whose driver returned rows is listed whatever this says.
    var declaredObjectKinds: Set<SidebarObjectKind> {
        var kinds: Set<SidebarObjectKind> = []
        if supportsRoutines {
            kinds.insert(.procedure)
            kinds.insert(.function)
        }
        if supportsDatabaseTriggerBrowse {
            kinds.insert(.trigger)
        }
        if supportsUserDefinedTypeBrowse {
            kinds.insert(.type)
        }
        return kinds
    }

    var supportsSchemaEditing: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.supportsSchemaEditing ?? true
    }

    var supportsAddColumn: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.capabilities.supportsAddColumn ?? true
    }

    var supportsModifyColumn: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.capabilities.supportsModifyColumn ?? true
    }

    var supportsDropColumn: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.capabilities.supportsDropColumn ?? true
    }

    var supportsRenameColumn: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.capabilities.supportsRenameColumn ?? false
    }

    var supportsAddIndex: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.capabilities.supportsAddIndex ?? true
    }

    var supportsDropIndex: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.capabilities.supportsDropIndex ?? true
    }

    var supportsModifyPrimaryKey: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.capabilities.supportsModifyPrimaryKey ?? true
    }
}
