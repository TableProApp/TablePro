//
//  PostgreSQLPluginDriver+EnumTypes.swift
//  PostgreSQLDriver
//

import Foundation
import OSLog
import TableProPluginKit

private let enumProbeLogger = Logger(
    subsystem: "com.TablePro.PostgreSQLDriver",
    category: "EnumTypeProbe"
)

extension PostgreSQLPluginDriver {
    func probeEnumOids() async {
        do {
            let result = try await core.execute(query: PostgreSQLSchemaQueries.enumTypeOidQuery)
            let rows = result.rows.map { row in row.map(\.asText) }
            core.mergeCatalogTypeNames(PostgreSQLCatalogTypeNames.enumProbeNames(rows: rows))
        } catch {
            enumProbeLogger.debug(
                "Enum OID probe failed; enum columns fall back to text for this session: \(error.localizedDescription)"
            )
        }
    }
}
