import AppKit
import SwiftUI
@_exported import TableProCoreTypes
import TableProPluginKit

typealias DatabaseType = TableProCoreTypes.DatabaseType

extension DatabaseType {
    private static var metadataRegistry: PluginMetadataRegistry { .shared }

    private var metadataSnapshot: PluginMetadataSnapshot? {
        Self.metadataRegistry.snapshot(forTypeId: rawValue)
    }

    private var pluginMetadataSnapshot: PluginMetadataSnapshot? {
        Self.metadataRegistry.snapshot(forTypeId: pluginTypeId)
    }

    init?(validating rawValue: String) {
        guard Self.metadataRegistry.hasType(rawValue) else { return nil }
        self.init(rawValue: rawValue)
    }

    var pluginTypeId: String {
        Self.metadataRegistry.pluginTypeId(for: rawValue)
    }

    var isDownloadablePlugin: Bool {
        pluginMetadataSnapshot?.isDownloadable ?? false
    }

    var iconName: String {
        metadataSnapshot?.iconName ?? "database-icon"
    }

    var iconImage: Image {
        let name = iconName
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return Image(systemName: name)
        }
        return Image(name).resizable()
    }

    var defaultPort: Int {
        metadataSnapshot?.defaultPort ?? 0
    }

    var defaultSSLMode: SSLMode {
        metadataSnapshot?.capabilities.defaultSSLMode ?? .disabled
    }

    var supportsOpportunisticTLS: Bool {
        metadataSnapshot?.capabilities.supportsOpportunisticTLS ?? true
    }

    var supportsClientKeyPassphrase: Bool {
        metadataSnapshot?.capabilities.supportsClientKeyPassphrase ?? false
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
        metadataSnapshot?.explainVariants ?? []
    }

    var category: DatabaseCategory {
        metadataSnapshot?.connection.category ?? .other
    }

    var pathFieldRole: PathFieldRole {
        metadataSnapshot?.pathFieldRole ?? .database
    }

    var tagline: String? {
        let raw = metadataSnapshot?.connection.tagline ?? ""
        return raw.isEmpty ? nil : raw
    }

    var brandColor: Color {
        switch rawValue {
        case "MySQL": Color(hex: "00758F")
        case "MariaDB": Color(hex: "C0765A")
        case "PostgreSQL": Color(hex: "336791")
        case "Redshift": Color(hex: "527FFF")
        case "CockroachDB": Color(hex: "6933FF")
        case "SQLite": Color(hex: "0F80CC")
        case "SQL Server": Color(hex: "CC2927")
        case "Oracle": Color(hex: "C74634")
        case "MongoDB": Color(hex: "00684A")
        case "Redis": Color(hex: "FF4438")
        case "ClickHouse": Color(hex: "FFCC01")
        case "DuckDB": Color(hex: "FFC827")
        case "Cassandra": Color(hex: "1287B1")
        case "ScyllaDB": Color(hex: "00C9C2")
        case "etcd": Color(hex: "419EDA")
        case "Cloudflare D1": Color(hex: "F38020")
        case "libSQL", "Turso": Color(hex: "4FF8D2")
        case "DynamoDB": Color(hex: "4053D6")
        case "BigQuery": Color(hex: "4285F4")
        default: Color.accentColor
        }
    }

    var requiresAuthentication: Bool {
        pluginMetadataSnapshot?.requiresAuthentication ?? true
    }

    var supportsForeignKeys: Bool {
        pluginMetadataSnapshot?.supportsForeignKeys ?? true
    }

    var supportsSchemaEditing: Bool {
        metadataSnapshot?.supportsSchemaEditing ?? true
    }

    var supportsAddColumn: Bool {
        metadataSnapshot?.capabilities.supportsAddColumn ?? true
    }

    var supportsModifyColumn: Bool {
        metadataSnapshot?.capabilities.supportsModifyColumn ?? true
    }

    var supportsDropColumn: Bool {
        metadataSnapshot?.capabilities.supportsDropColumn ?? true
    }

    var supportsRenameColumn: Bool {
        metadataSnapshot?.capabilities.supportsRenameColumn ?? false
    }

    var supportsAddIndex: Bool {
        metadataSnapshot?.capabilities.supportsAddIndex ?? true
    }

    var supportsDropIndex: Bool {
        metadataSnapshot?.capabilities.supportsDropIndex ?? true
    }

    var supportsModifyPrimaryKey: Bool {
        metadataSnapshot?.capabilities.supportsModifyPrimaryKey ?? true
    }
}
