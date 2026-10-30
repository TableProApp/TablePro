//
//  PluginMetadataRegistry+KingbaseESDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    // Created by initdb on V9R1C10; dbms_sql, sys and wmsys exist only in an Oracle-mode cluster.
    static let kingbaseESSystemSchemaNames = [
        "pg_catalog", "information_schema", "pg_toast", "sys_catalog", "sys", "anon", "dbms_job", "dbms_scheduler",
        "dbms_sql", "kdb_schedule", "perf", "pg_bitmapindex", "src_restrict", "sys_hm", "sysaudit", "sysmac", "wmsys",
        "xlog_record_read",
    ]

    /// KingbaseES runs PostgreSQL's catalogs and wire protocol, so its entry is PostgreSQL's with its own identity
    /// and without the cloud and Kerberos sign-in fields, which its servers do not offer.
    static func kingbaseESDefaults(postgreSQL: PluginMetadataSnapshot) -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        [("KingbaseES", PluginMetadataSnapshot(
            displayName: "KingbaseES", iconName: "cylinder", defaultPort: 54_321,
            requiresAuthentication: true, supportsForeignKeys: postgreSQL.supportsForeignKeys,
            supportsSchemaEditing: postgreSQL.supportsSchemaEditing, isDownloadable: true,
            primaryUrlScheme: "kingbase", parameterStyle: .dollar,
            navigationModel: postgreSQL.navigationModel, explainVariants: postgreSQL.explainVariants,
            pathFieldRole: .database, supportsHealthMonitor: postgreSQL.supportsHealthMonitor,
            urlSchemes: ["kingbase", "kingbase8"], postConnectActions: postgreSQL.postConnectActions,
            brandColorHex: "#C9141E", queryLanguageName: "SQL", editorLanguage: .sql,
            connectionMode: .network, supportsDatabaseSwitching: postgreSQL.supportsDatabaseSwitching,
            structureEditing: postgreSQL.structureEditing,
            capabilities: postgreSQL.capabilities, schema: postgreSQL.schema, editor: postgreSQL.editor,
            connection: PluginMetadataSnapshot.ConnectionConfig(
                additionalConnectionFields: postgreSQL.connection.additionalConnectionFields.filter {
                    ["usePgpass", "connectionOptions"].contains($0.id)
                },
                category: .relational,
                tagline: String(localized: "PostgreSQL and Oracle compatible SQL")
            )
        ).withSystemNames(databases: postgreSQL.schema.systemDatabaseNames, schemas: kingbaseESSystemSchemaNames))]
    }
}
