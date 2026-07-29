//
//  PostgreSQLPrincipalQueries.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

enum PostgreSQLRoleAttribute: String, CaseIterable {
    case superuser = "SUPERUSER"
    case createdb = "CREATEDB"
    case createrole = "CREATEROLE"
    case replication = "REPLICATION"
    case bypassrls = "BYPASSRLS"
    case inherit = "INHERIT"

    var label: String {
        switch self {
        case .superuser: "Superuser"
        case .createdb: "Create databases"
        case .createrole: "Create roles"
        case .replication: "Replication"
        case .bypassrls: "Bypass row level security"
        case .inherit: "Inherit privileges"
        }
    }

    var catalogColumn: String {
        switch self {
        case .superuser: "rolsuper"
        case .createdb: "rolcreatedb"
        case .createrole: "rolcreaterole"
        case .replication: "rolreplication"
        case .bypassrls: "rolbypassrls"
        case .inherit: "rolinherit"
        }
    }

    var negatedKeyword: String { "NO\(rawValue)" }

    func keyword(isEnabled: Bool) -> String {
        isEnabled ? rawValue : negatedKeyword
    }
}

enum PostgreSQLPrincipalQueries {
    private static let data = PluginPrivilegeCategoryKey.data
    private static let structure = PluginPrivilegeCategoryKey.structure
    private static let administration = PluginPrivilegeCategoryKey.administration

    static let databasePrivileges = [
        PluginPrivilegeDescriptor(name: "CONNECT", label: "Connect", category: administration),
        PluginPrivilegeDescriptor(name: "CREATE", label: "Create", category: structure),
        PluginPrivilegeDescriptor(name: "TEMPORARY", label: "Temporary tables", category: structure)
    ]

    static let schemaPrivileges = [
        PluginPrivilegeDescriptor(name: "USAGE", label: "Usage", category: administration),
        PluginPrivilegeDescriptor(name: "CREATE", label: "Create", category: structure)
    ]

    static let tablePrivileges = [
        PluginPrivilegeDescriptor(name: "SELECT", label: "Select", category: data),
        PluginPrivilegeDescriptor(name: "INSERT", label: "Insert", category: data),
        PluginPrivilegeDescriptor(name: "UPDATE", label: "Update", category: data),
        PluginPrivilegeDescriptor(name: "DELETE", label: "Delete", category: data),
        PluginPrivilegeDescriptor(name: "TRUNCATE", label: "Truncate", category: structure),
        PluginPrivilegeDescriptor(name: "REFERENCES", label: "References", category: structure),
        PluginPrivilegeDescriptor(name: "TRIGGER", label: "Trigger", category: structure)
    ]

    static let columnPrivileges = [
        PluginPrivilegeDescriptor(name: "SELECT", label: "Select", category: data),
        PluginPrivilegeDescriptor(name: "INSERT", label: "Insert", category: data),
        PluginPrivilegeDescriptor(name: "UPDATE", label: "Update", category: data),
        PluginPrivilegeDescriptor(name: "REFERENCES", label: "References", category: structure)
    ]

    static func searchObjects(patternLiteral: String, limit: Int) -> String {
        """
        SELECT n.nspname, c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'v', 'm', 'p', 'f')
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND c.relname ILIKE '%\(patternLiteral)%'
        ORDER BY n.nspname, c.relname
        LIMIT \(max(1, limit))
        """
    }

    static let schemas = """
        SELECT n.nspname
        FROM pg_namespace n
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND n.nspname NOT LIKE 'pg\\_%'
        ORDER BY n.nspname
        """

    static func tables(schemaLiteral: String) -> String {
        """
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = '\(schemaLiteral)'
          AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
        ORDER BY c.relname
        """
    }

    static func columns(schemaLiteral: String, tableLiteral: String) -> String {
        """
        SELECT a.attname
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = '\(schemaLiteral)'
          AND c.relname = '\(tableLiteral)'
          AND a.attnum > 0
          AND NOT a.attisdropped
        ORDER BY a.attnum
        """
    }

    static func columnGrants(roleLiteral: String) -> String {
        """
        SELECT n.nspname, c.relname, a.attname, acl.privilege_type, acl.is_grantable
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN LATERAL aclexplode(a.attacl) AS acl
        JOIN pg_roles r ON r.oid = acl.grantee
        WHERE r.rolname = '\(roleLiteral)'
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
        ORDER BY n.nspname, c.relname, a.attname, acl.privilege_type
        """
    }

    static func principals(includeBypassRLS: Bool) -> String {
        let bypassColumn = includeBypassRLS ? "r.rolbypassrls" : "false AS rolbypassrls"
        return """
            SELECT r.rolname,
                   r.rolcanlogin,
                   r.rolsuper,
                   r.rolcreatedb,
                   r.rolcreaterole,
                   r.rolreplication,
                   \(bypassColumn),
                   r.rolinherit,
                   r.rolconnlimit,
                   pg_catalog.shobj_description(r.oid, 'pg_authid')
            FROM pg_roles r
            WHERE r.rolname NOT LIKE 'pg\\_%'
            ORDER BY r.rolname
            """
    }

    static let memberships = """
        SELECT member.rolname, grantedRole.rolname
        FROM pg_auth_members m
        JOIN pg_roles member ON member.oid = m.member
        JOIN pg_roles grantedRole ON grantedRole.oid = m.roleid
        ORDER BY member.rolname, grantedRole.rolname
        """

    static func databaseGrants(roleLiteral: String) -> String {
        """
        SELECT d.datname, a.privilege_type, a.is_grantable
        FROM pg_database d
        CROSS JOIN LATERAL aclexplode(d.datacl) AS a
        JOIN pg_roles r ON r.oid = a.grantee
        WHERE r.rolname = '\(roleLiteral)'
          AND NOT d.datistemplate
        ORDER BY d.datname, a.privilege_type
        """
    }

    static func schemaGrants(roleLiteral: String) -> String {
        """
        SELECT n.nspname, a.privilege_type, a.is_grantable
        FROM pg_namespace n
        CROSS JOIN LATERAL aclexplode(n.nspacl) AS a
        JOIN pg_roles r ON r.oid = a.grantee
        WHERE r.rolname = '\(roleLiteral)'
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
        ORDER BY n.nspname, a.privilege_type
        """
    }

    static func tableGrants(roleLiteral: String) -> String {
        """
        SELECT n.nspname, c.relname, a.privilege_type, a.is_grantable
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN LATERAL aclexplode(c.relacl) AS a
        JOIN pg_roles r ON r.oid = a.grantee
        WHERE r.rolname = '\(roleLiteral)'
          AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
        ORDER BY n.nspname, c.relname, a.privilege_type
        """
    }

    static func ownsObjects(roleLiteral: String) -> String {
        """
        SELECT EXISTS (
            SELECT 1
            FROM pg_shdepend s
            JOIN pg_roles r ON r.oid = s.refobjid
            WHERE r.rolname = '\(roleLiteral)'
              AND s.deptype IN ('o', 'a')
        )
        """
    }

    static let currentPrincipal = "SELECT current_user"
    static let currentDatabase = "SELECT current_database()"
}
