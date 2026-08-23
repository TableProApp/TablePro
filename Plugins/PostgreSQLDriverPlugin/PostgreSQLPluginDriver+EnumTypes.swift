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
            var map: [UInt32: String] = [:]
            for row in result.rows {
                guard row.count >= 3,
                      let typeName = row[2].asText,
                      let scalarOid = row[0].asText.flatMap({ UInt32($0) }) else { continue }
                map[scalarOid] = "ENUM(\(typeName))"
                if let arrayOid = row[1].asText.flatMap({ UInt32($0) }), arrayOid != 0 {
                    map[arrayOid] = "ENUM[](\(typeName))"
                }
            }
            core.setEnumOidMap(map)
        } catch {
            enumProbeLogger.debug(
                "Enum OID probe failed; enum columns fall back to text for this session: \(error.localizedDescription)"
            )
        }
    }
}
