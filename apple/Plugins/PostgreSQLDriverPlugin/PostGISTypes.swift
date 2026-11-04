//
//  PostGISTypes.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProGeometry
import TableProPluginKit

enum PostGISTypes {
    // Only the postgis extension's own base types arrive as EWKB; another role's enum or domain named geometry does not.
    static let probeQuery = """
        SELECT t.oid, t.typname
        FROM pg_catalog.pg_type t
        JOIN pg_catalog.pg_depend d
            ON d.classid = 'pg_catalog.pg_type'::pg_catalog.regclass AND d.objid = t.oid AND d.deptype = 'e'
            AND d.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
        JOIN pg_catalog.pg_extension x ON x.oid = d.refobjid
        WHERE t.typtype = 'b' AND t.typname IN ('geometry', 'geography') AND x.extname = 'postgis'
        """

    static func names(fromProbeRows rows: [[String?]]) -> [UInt32: String] {
        var names: [UInt32: String] = [:]
        for row in rows {
            guard row.count >= 2, let oid = row[0].flatMap({ UInt32($0) }), let name = row[1] else { continue }
            names[oid] = name
        }
        return names
    }

    // Written here rather than by ST_AsEWKT on the server, so rendering calls no function on the user's session. A value
    // that does not read as EWKB keeps its hex.
    static func rendering(_ result: LibPQPluginQueryResult, types: [UInt32: String]) -> LibPQPluginQueryResult {
        guard !types.isEmpty, result.columnOids.contains(where: { types[$0] != nil }) else { return result }
        var rows = result.rows
        var columnTypeNames = result.columnTypeNames
        for (index, oid) in result.columnOids.enumerated() {
            guard let typeName = types[oid] else { continue }
            if index < columnTypeNames.count {
                columnTypeNames[index] = typeName
            }
            for rowIndex in rows.indices where index < rows[rowIndex].count {
                guard case .text(let hex) = rows[rowIndex][index], let text = EWKTWriter.string(fromHex: hex) else {
                    continue
                }
                rows[rowIndex][index] = .text(text)
            }
        }
        return LibPQPluginQueryResult(
            columns: result.columns,
            columnOids: result.columnOids,
            columnTypeNames: columnTypeNames,
            rows: rows,
            affectedRows: result.affectedRows,
            commandTag: result.commandTag,
            isTruncated: result.isTruncated,
            firstRowTime: result.firstRowTime
        )
    }
}
