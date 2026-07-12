//
//  MySQLPrivilegeCatalog.swift
//  MySQLDriverPlugin
//
//  MySQL's static privileges are a closed set. Anything SHOW PRIVILEGES reports that is not in it
//  is a dynamic privilege registered by a component or plugin (MySQL 8+). Classifying by name
//  membership rather than by a character heuristic keeps a privilege like CREATE_TABLESPACE_ADMIN
//  from being misfiled, and keeps a future static privilege from being called dynamic.
//

import Foundation
import TableProPluginKit

enum MySQLPrivilegeCatalog {
    static let dataPrivileges: Set<String> = [
        "SELECT", "INSERT", "UPDATE", "DELETE", "EXECUTE", "SHOW VIEW", "LOCK TABLES"
    ]

    static let structurePrivileges: Set<String> = [
        "CREATE", "DROP", "ALTER", "INDEX", "CREATE VIEW", "CREATE ROUTINE", "ALTER ROUTINE",
        "CREATE TEMPORARY TABLES", "EVENT", "TRIGGER", "REFERENCES", "CREATE TABLESPACE"
    ]

    static let administrationPrivileges: Set<String> = [
        "CREATE USER", "CREATE ROLE", "DROP ROLE", "FILE", "PROCESS", "RELOAD",
        "REPLICATION CLIENT", "REPLICATION SLAVE", "SHOW DATABASES", "SHUTDOWN", "SUPER",
        "GRANT OPTION", "PROXY", "USAGE"
    ]

    static let staticPrivilegeNames: Set<String> =
        dataPrivileges.union(structurePrivileges).union(administrationPrivileges)

    static func isDynamic(_ name: String) -> Bool {
        !staticPrivilegeNames.contains(name)
    }

    static func category(for name: String) -> String {
        if dataPrivileges.contains(name) { return PluginPrivilegeCategoryKey.data }
        if structurePrivileges.contains(name) { return PluginPrivilegeCategoryKey.structure }
        if administrationPrivileges.contains(name) { return PluginPrivilegeCategoryKey.administration }
        return PluginPrivilegeCategoryKey.dynamic
    }
}
