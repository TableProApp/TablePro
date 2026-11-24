//
//  RedshiftSchemaQueries.swift
//  PostgreSQLDriverPlugin
//

import Foundation

nonisolated enum RedshiftSchemaQueries {
    static func columnsQuery(schema: String, table: String?) -> String {
        ColumnQueryShape.informationSchemaColumnsQuery(schema: schema, table: table)
    }
}
