import Foundation
import TableProPluginKit

public enum BigQueryObjectQueries {
    public static func routineList(project: String, dataset: String) -> String {
        let source = BigQueryQueryBuilder.qualifiedTable(
            projectId: project,
            dataset: dataset,
            table: "INFORMATION_SCHEMA"
        )
        return """
        SELECT routine_name, routine_schema, routine_type, data_type, language, ddl
        FROM \(source).ROUTINES
        ORDER BY routine_type, routine_name
        """
    }
}

extension BigQueryPluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        let datasetId = dataset(for: schema)
        guard !datasetId.isEmpty else { return [] }
        let conn = try requireConnection()
        let result: BQExecuteResult
        do {
            result = try await conn.executeQuery(
                BigQueryObjectQueries.routineList(project: conn.projectId, dataset: datasetId),
                defaultDataset: datasetId
            )
        } catch {
            throw BigQueryError.wrap(error)
        }
        return (result.queryResponse.rows ?? []).compactMap { Self.routine(from: $0, dataset: datasetId) }
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        if let ddl = routine.definition, !ddl.isEmpty { return ddl }
        let listed = try await fetchRoutines(schema: routine.schema)
        guard let ddl = listed.first(where: { $0.name == routine.name })?.definition, !ddl.isEmpty else {
            throw PluginObjectSourceError.notFound(routine.name)
        }
        return ddl
    }

    private static func routine(from row: BQQueryResponse.BQRow, dataset: String) -> PluginRoutineInfo? {
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
