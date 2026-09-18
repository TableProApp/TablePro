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
    static let publicKeyword = "PUBLIC"

    /// Decided by the grantee's own kind, never by comparing its name. PostgreSQL allows a quoted
    /// role called `public`, and reading the name meant a grant to that role was written as
    /// `TO PUBLIC` and handed to every user on the server.
    static func render(_ grantee: PluginSchemaGrantee) -> String {
        switch grantee {
        case .publicGroup: publicKeyword
        case .role(let name): PostgreSQLObjectQueries.quoteIdentifier(name)
        }
    }

    static func ownerAndComment(schema: String) -> String {
        """
        SELECT pg_catalog.pg_get_userbyid(n.nspowner),
               pg_catalog.obj_description(n.oid, 'pg_namespace'),
               pg_catalog.current_user
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
    ///
    /// The grantee id comes back as its own column so the caller can tell the all-users group
    /// (id zero) from a role whose name happens to be `public`. The grantor comes back because
    /// `REVOKE` only removes what the executing role granted.
    static func grants(schema: String) -> String {
        """
        SELECT (s.acl).grantee,
               COALESCE(gte.rolname, ''),
               (s.acl).privilege_type,
               (s.acl).is_grantable,
               COALESCE(gtr.rolname, '')
        FROM (
            SELECT pg_catalog.aclexplode(n.nspacl) AS acl
            FROM pg_catalog.pg_namespace n
            WHERE n.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema))
              AND n.nspacl IS NOT NULL
        ) s
        LEFT JOIN pg_catalog.pg_roles gte ON gte.oid = (s.acl).grantee
        LEFT JOIN pg_catalog.pg_roles gtr ON gtr.oid = (s.acl).grantor
        ORDER BY 2, 3
        """
    }

    static func create(name: String, owner: String?) -> String {
        let identifier = PostgreSQLObjectQueries.quoteIdentifier(name)
        guard let owner, !owner.isEmpty else { return "CREATE SCHEMA \(identifier)" }
        return "CREATE SCHEMA \(identifier) AUTHORIZATION"
            + " \(PostgreSQLObjectQueries.quoteIdentifier(owner))"
    }

    static func rename(name: String, to newName: String) -> String {
        let identifier = PostgreSQLObjectQueries.quoteIdentifier(name)
        return "ALTER SCHEMA \(identifier) RENAME TO \(PostgreSQLObjectQueries.quoteIdentifier(newName))"
    }

    /// An owner is always a real role, never the pseudo-group, so it is quoted unconditionally.
    static func changeOwner(name: String, to owner: String) -> String {
        let identifier = PostgreSQLObjectQueries.quoteIdentifier(name)
        return "ALTER SCHEMA \(identifier) OWNER TO \(PostgreSQLObjectQueries.quoteIdentifier(owner))"
    }

    /// An empty comment clears it, which PostgreSQL spells as NULL rather than as an empty string:
    /// `IS ''` leaves an empty comment behind that `obj_description` then reports as present.
    static func comment(name: String, to comment: String?) -> String {
        let identifier = PostgreSQLObjectQueries.quoteIdentifier(name)
        guard let comment, !comment.isEmpty else { return "COMMENT ON SCHEMA \(identifier) IS NULL" }
        return "COMMENT ON SCHEMA \(identifier) IS \(PostgreSQLObjectQueries.quoteLiteral(comment))"
    }
}
