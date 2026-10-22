//
//  MySQLPluginDriver+TemporaryTables.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension MySQLPluginDriver {
    // TiDB and OceanBase keep temporary tables too, unmeasured here.
    var listsTemporaryTables: Bool {
        flavor == .mysql || flavor == .mariadb
    }

    func fetchTemporaryTables() async throws -> [PluginTableInfo] {
        guard listsTemporaryTables else { return [] }
        var tables: [String: PluginTableInfo] = [:]
        for candidate in temporaryTableCandidates {
            let result: PluginQueryResult
            do {
                result = try await executeSetup("SHOW CREATE TABLE \(quoteIdentifier(candidate))")
            } catch let error as MariaDBPluginError where Self.isServerRefusal(error) {
                continue
            }
            guard let row = result.rows.first,
                  let name = row[safe: 0]?.asText,
                  let ddl = row[safe: 1]?.asText,
                  MySQLTemporaryTableNames.declaresTemporaryTable(ddl)
            else { continue }
            // Under lower_case_table_names two spellings reach one table; the server answers its own name.
            tables[name] = PluginTableInfo(name: name, type: "TABLE")
        }
        return tables.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // The catalog describes permanent tables only: for a temporary table that hides one, every catalog read answers
    // with the hidden table, so those reads go through `SHOW` or answer empty.
    func resolvesToTemporaryTable(_ table: String, schema: String?) async -> Bool {
        guard listsTemporaryTables,
              temporaryTableCandidates.contains(where: { $0.caseInsensitiveCompare(table) == .orderedSame })
        else { return false }
        guard let result = try? await executeSetup("SHOW CREATE TABLE \(qualifiedName(table, schema: schema))"),
              let ddl = result.rows.first?[safe: 1]?.asText
        else { return false }
        return MySQLTemporaryTableNames.declaresTemporaryTable(ddl)
    }

    // 1146 for a table that is gone, 1046 with no database selected: the candidate is not a temporary table here.
    private static func isServerRefusal(_ error: MariaDBPluginError) -> Bool {
        error.code != 0 && !MySQLTableListing.clientErrorCodes.contains(error.code)
    }
}
