import Foundation
@testable import TableProSpannerCore
import Testing

@Suite(
    "SpannerExecutor against the emulator",
    .enabled(if: SpannerEmulatorEnvironment.host != nil),
    .serialized
)
struct SpannerExecutorEmulatorTests {
    private func makeExecutor(database: String) async throws -> SpannerExecutor {
        let settings = try SpannerConnectionSettings.parse(fields: [
            SpannerConnectionSettings.FieldKey.projectId: SpannerEmulatorEnvironment.value("SPANNER_EMULATOR_PROJECT") ?? "proj",
            SpannerConnectionSettings.FieldKey.instanceId: SpannerEmulatorEnvironment.value("SPANNER_EMULATOR_INSTANCE") ?? "inst",
            SpannerConnectionSettings.FieldKey.databaseId: database,
            SpannerConnectionSettings.FieldKey.endpoint: SpannerEmulatorEnvironment.host ?? "",
            SpannerConnectionSettings.FieldKey.authMethod: SpannerAuthMethod.emulator.rawValue
        ])
        let transport = URLSessionSpannerTransport(requestTimeout: { 60 })
        let client = SpannerRESTClient(settings: settings, transport: transport, tokenProvider: nil)
        let dialect = SpannerDialect(databaseDialect: try await client.databaseDialect())
        return SpannerExecutor(client: client, dialect: dialect, ddlDeadline: { .seconds(60) })
    }

    @Test("GoogleSQL: DDL, typed DML through placeholders, transactions, EXPLAIN and reads")
    func googleSQLRoundTrip() async throws {
        let executor = try await makeExecutor(database: "gdb")
        defer { Task { await executor.shutdown() } }
        _ = try? await executor.run("DROP TABLE exec_probe_g", hostParameters: nil)
        _ = try await executor.run(
            """
            CREATE TABLE exec_probe_g (Id INT64 NOT NULL, Name STRING(MAX), Active BOOL, Score FLOAT64,
            Tags ARRAY<INT64>, Photo BYTES(MAX), Note STRING(MAX)) PRIMARY KEY (Id)
            """,
            hostParameters: nil
        )

        let inserted = try await executor.run(
            "INSERT INTO exec_probe_g (Id, Name, Active, Score, Tags, Photo, Note) VALUES (?, ?, ?, ?, ?, ?, ?)",
            hostParameters: [
                .text("1"), .text("O'Brien \\ 'quoted' ?"), .text("true"), .text("1.5"), .text("[1, 2]"),
                .bytes(Data([0, 255])), .null
            ]
        )
        #expect(inserted.rowsAffected == 1)

        let read = try await executor.run(
            "SELECT Name, Active, Score, Tags, Photo, Note FROM exec_probe_g WHERE Id = ?",
            hostParameters: [.text("1")]
        )
        #expect(read.rows == [[
            .text("O'Brien \\ 'quoted' ?"), .text("true"), .text("1.5"), .text("[1,2]"), .bytes(Data([0, 255])), .null
        ]])

        _ = try await executor.run("BEGIN", hostParameters: nil)
        _ = try await executor.run("UPDATE exec_probe_g SET Name = ? WHERE Id = ?", hostParameters: [.text("rolled"), .text("1")])
        _ = try await executor.run("ROLLBACK", hostParameters: nil)
        let afterRollback = try await executor.run("SELECT Name FROM exec_probe_g WHERE Id = 1", hostParameters: nil)
        #expect(afterRollback.rows == [[.text("O'Brien \\ 'quoted' ?")]])

        try await executor.beginTransaction()
        _ = try await executor.run("UPDATE exec_probe_g SET Name = ? WHERE Id = ?", hostParameters: [.text("kept"), .text("1")])
        try await executor.commitTransaction()

        let plan = try await executor.run("EXPLAIN DELETE FROM exec_probe_g WHERE TRUE", hostParameters: nil)
        #expect(plan.fields.map(\.name) == [SpannerPlanRenderer.columnName])
        await #expect(throws: SpannerExecutionError.self) {
            _ = try await executor.run("EXPLAIN DROP TABLE exec_probe_g", hostParameters: nil)
        }
        let remaining = try await executor.read(SpannerRenderedStatement(sql: "SELECT Name FROM exec_probe_g"))
        #expect(remaining == [[.text("kept")]])

        _ = try await executor.run("DROP TABLE exec_probe_g", hostParameters: nil)
    }

    @Test("PostgreSQL dialect: $n placeholders, typed DML and EXPLAIN")
    func postgreSQLRoundTrip() async throws {
        let executor = try await makeExecutor(database: "pg")
        defer { Task { await executor.shutdown() } }
        #expect(executor.dialect == .postgreSQL)
        _ = try? await executor.run("DROP TABLE exec_probe_p", hostParameters: nil)
        _ = try await executor.run(
            "CREATE TABLE exec_probe_p (id bigint NOT NULL PRIMARY KEY, name varchar, active boolean, doc jsonb)",
            hostParameters: nil
        )

        _ = try await executor.run(
            "INSERT INTO exec_probe_p (id, name, active, doc) VALUES (?, ?, ?, ?)",
            hostParameters: [.text("7"), .text("O'Brien\\"), .text("false"), .text(#"{"a": 1}"#)]
        )
        let read = try await executor.run("SELECT name, active FROM exec_probe_p WHERE id = ?", hostParameters: [.text("7")])
        #expect(read.rows == [[.text("O'Brien\\"), .text("false")]])

        let plan = try await executor.run("EXPLAIN DELETE FROM exec_probe_p", hostParameters: nil)
        #expect(!plan.rows.isEmpty)
        let count = try await executor.read(SpannerRenderedStatement(sql: "SELECT COUNT(*) FROM exec_probe_p"))
        #expect(count == [[.text("1")]])

        _ = try await executor.run("DROP TABLE exec_probe_p", hostParameters: nil)
    }
}
