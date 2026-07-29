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

enum PostGISSpatialRewrite {
    static let probeQuery = "SELECT oid, typname FROM pg_type WHERE typname IN ('geometry', 'geography')"

    static let geometryConversionQuery =
        "SELECT ST_AsEWKT(t::geometry) FROM unnest($1::text[]) WITH ORDINALITY AS x(t, ord) ORDER BY ord"
    static let geographyConversionQuery =
        "SELECT ST_AsEWKT(t::geography) FROM unnest($1::text[]) WITH ORDINALITY AS x(t, ord) ORDER BY ord"

    static func conversionQuery(forTypeName typeName: String) -> String? {
        switch typeName {
        case "geometry": return geometryConversionQuery
        case "geography": return geographyConversionQuery
        default: return nil
        }
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
