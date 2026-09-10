//
//  BigQueryPluginDriver+Routines.swift
//  BigQueryDriverPlugin
//

import Foundation
import TableProPluginKit

/// BigQuery has procedures and functions and no triggers.
public enum BigQueryObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    /// The ddl column holds the whole CREATE statement, so the list and the source are one read.
    public static func routineList(project: String, dataset: String) -> String {
        """
        SELECT routine_name, routine_schema, routine_type, data_type, language, ddl
        FROM `\(project).\(dataset).INFORMATION_SCHEMA.ROUTINES`
        ORDER BY routine_type, routine_name
        """
    }
}

extension BigQueryPluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        guard let conn = connection else { throw BigQueryError.notConnected }
        let dataset = schema ?? currentSchema ?? ""
        guard !dataset.isEmpty else { return [] }
        let sql = BigQueryObjectQueries.routineList(project: conn.projectId, dataset: dataset)
        let result = try await conn.executeQuery(sql, defaultDataset: dataset)
        return (result.queryResponse.rows ?? []).compactMap { row -> PluginRoutineInfo? in
            let cells = row.f ?? []
            func text(_ index: Int) -> String? {
                guard index < cells.count, case .string(let value) = cells[index].v else { return nil }
                return value
            }
            guard let name = text(0) else { return nil }
            let isProcedure = (text(2) ?? "").uppercased() == "PROCEDURE"
            return PluginRoutineInfo(
                name: name,
                kind: isProcedure ? .procedure : .function,
                schema: text(1) ?? dataset,
                returnType: text(3),
                language: text(4),
                argumentSignature: nil,
                identity: nil,
                definition: text(5),
                attributes: []
            )
        }
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        if let ddl = routine.definition, !ddl.isEmpty { return ddl }
        let listed = try await fetchRoutines(schema: routine.schema)
        guard let ddl = listed.first(where: { $0.name == routine.name })?.definition, !ddl.isEmpty else {
            throw PluginObjectSourceError.notFound(routine.name)
        }
        return ddl
    }
}
