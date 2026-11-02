//
//  PostgreSQLPluginDriver+EnumTypes.swift
//  PostgreSQLDriver
//

import Foundation
import os
import OSLog
import TableProPluginKit
import TableProPostgreSQLCore

private let enumProbeLogger = Logger(
    subsystem: "com.TablePro.PostgreSQLDriver",
    category: "EnumTypeProbe"
)

extension PostgreSQLPluginDriver {
    func probeEnumOids() async {
        do {
            let result = try await core.executeCatalogRead(PostgreSQLSchemaQueries.enumTypeOidQuery)
            let rows = result.rows.map { row in row.map(\.asText) }
            core.mergeCatalogTypeNames(PostgreSQLCatalogTypeNames.enumProbeNames(rows: rows))
        } catch {
            enumProbeLogger.debug(
                "Enum OID probe failed; enum columns fall back to text for this session: \(error.localizedDescription)"
            )
        }
    }
}
