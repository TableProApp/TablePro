//
//  PostGISSpatialRewrite.swift
//  PostgreSQLDriverPlugin
//
//  PostGIS rendering support. Geometry and geography values arrive from libpq as
//  raw EWKB hex (e.g. "0101000020E6100000..."). To surface them as readable WKT
//  with SRID, we probe pg_type for the dynamic PostGIS OIDs at connect time and,
//  when a result set contains spatial columns, convert the already-fetched hex
//  values with a separate side-effect-free query. The original user statement is
//  never re-executed: the conversion runs ST_AsEWKT over an array of the fetched
//  values, so it can't double-apply side effects and works the same regardless of
//  whether the query was parameterized.
//

import Foundation

struct PostGISType: Equatable, Sendable {
    let name: String
    let schema: String
}

enum PostGISSpatialRewrite {
    static let probeQuery = """
        SELECT t.oid, t.typname, n.nspname
        FROM pg_catalog.pg_type t
        JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname IN ('geometry', 'geography')
        """

    /// A user savepoint of the same name is safe: PostgreSQL resolves a repeated savepoint name to
    /// the newest one, so this RELEASE removes only the savepoint the rendering pass opened.
    static let savepoint = "SAVEPOINT tablepro_spatial_render"
    static let releaseSavepoint = "RELEASE SAVEPOINT tablepro_spatial_render"
    static let rollbackToSavepoint = "ROLLBACK TO SAVEPOINT tablepro_spatial_render"

    static func conversionQuery(for type: PostGISType) -> String? {
        guard type.name == "geometry" || type.name == "geography" else { return nil }
        let schema = PostgreSQLObjectQueries.quoteIdentifier(type.schema)
        let qualifiedType = PostgreSQLObjectQueries.qualifiedName(schema: type.schema, name: type.name)
        return "SELECT \(schema).ST_AsEWKT(($1::text[])[i]::\(qualifiedType)) "
            + "FROM pg_catalog.generate_subscripts($1::text[], 1) AS i ORDER BY i"
    }

    static func arrayLiteral(from values: [String?]) -> String {
        let elements = values.map { value -> String in
            guard let value else { return "NULL" }
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return "{\(elements.joined(separator: ","))}"
    }
}
