//
//  PostgreSQLSchemaManagementQueries.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

enum PostgreSQLSchemaManagementQueries {
    /// The pseudo-role every schema ACL can name. It is a keyword rather than a role name, so it
    /// is never quoted: `GRANT USAGE ON SCHEMA s TO "PUBLIC"` names a role literally called
    /// PUBLIC, which almost never exists, instead of granting to everyone.
    static let publicRole = "PUBLIC"

    static func isPublicRole(_ name: String) -> Bool {
        name.caseInsensitiveCompare(publicRole) == .orderedSame
    }

    static func quoteGrantee(_ name: String) -> String {
        isPublicRole(name) ? publicRole : PostgreSQLObjectQueries.quoteIdentifier(name)
    }

    static func ownerAndComment(schema: String) -> String {
        """
        SELECT pg_catalog.pg_get_userbyid(n.nspowner),
               pg_catalog.obj_description(n.oid, 'pg_namespace')
        FROM pg_catalog.pg_namespace n
        WHERE n.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema))
        """
    }

    /// `aclexplode` of a NULL `nspacl` yields no rows, which is the right answer: a schema nobody
    /// has been granted anything on carries the owner's implicit privileges alone, and those are
    /// reported through the owner rather than as grants the user could revoke.
    ///
    /// The set-returning function goes in the SELECT list of a subquery rather than in a
    /// `CROSS JOIN LATERAL`, which is what `PostgreSQLPrincipalQueries.schemaGrants` does and why:
    /// `LATERAL` arrived in PostgreSQL 9.3 and the driver connects to older servers than that.
    /// Grantee 0 is the PUBLIC pseudo-role, which `pg_roles` has no row for, so it is named here
    /// rather than joined; a role dropped out from under a surviving grant lands there too.
    static func grants(schema: String) -> String {
        """
        SELECT CASE WHEN (s.acl).grantee = 0 THEN '\(publicRole)'
                    ELSE COALESCE(r.rolname, '\(publicRole)') END,
               (s.acl).privilege_type,
               (s.acl).is_grantable
        FROM (
            SELECT pg_catalog.aclexplode(n.nspacl) AS acl
            FROM pg_catalog.pg_namespace n
            WHERE n.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema))
              AND n.nspacl IS NOT NULL
        ) s
        LEFT JOIN pg_catalog.pg_roles r ON r.oid = (s.acl).grantee
        ORDER BY 1, 2
        """
    }

    static func create(name: String, owner: String?) -> String {
        let identifier = PostgreSQLObjectQueries.quoteIdentifier(name)
        guard let owner, !owner.isEmpty else { return "CREATE SCHEMA \(identifier)" }
        return "CREATE SCHEMA \(identifier) AUTHORIZATION \(quoteGrantee(owner))"
    }

    static func rename(name: String, to newName: String) -> String {
        let identifier = PostgreSQLObjectQueries.quoteIdentifier(name)
        return "ALTER SCHEMA \(identifier) RENAME TO \(PostgreSQLObjectQueries.quoteIdentifier(newName))"
    }

    static func changeOwner(name: String, to owner: String) -> String {
        let identifier = PostgreSQLObjectQueries.quoteIdentifier(name)
        return "ALTER SCHEMA \(identifier) OWNER TO \(quoteGrantee(owner))"
    }

    /// An empty comment clears it, which PostgreSQL spells as NULL rather than as an empty string:
    /// `IS ''` leaves an empty comment behind that `obj_description` then reports as present.
    static func comment(name: String, to comment: String?) -> String {
        let identifier = PostgreSQLObjectQueries.quoteIdentifier(name)
        guard let comment, !comment.isEmpty else { return "COMMENT ON SCHEMA \(identifier) IS NULL" }
        return "COMMENT ON SCHEMA \(identifier) IS \(PostgreSQLObjectQueries.quoteLiteral(comment))"
    }
}
