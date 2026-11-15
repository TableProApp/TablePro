import Foundation
import TableProPluginKit
import Testing

struct RedshiftCatalogExportTests {
    private static func catalog(_ recorder: CatalogReadRecorder, externalSchemas: Set<String> = []) -> RedshiftCatalogExport {
        RedshiftCatalogExport(
            read: recorder.redshiftRead,
            currentSchema: "public",
            database: "dev",
            serverVersionNumber: 80_002,
            externalSchemas: externalSchemas
        )
    }

    private struct Refused: Error {}

    @Test("SHOW TABLE answers the DDL when the cluster has it")
    func showTableAnswers() async throws {
        let recorder = CatalogReadRecorder { _ in [["CREATE TABLE public.orders (id integer)"].cells] }
        let ddl = try await Self.catalog(recorder).fetchTableDDL(table: "orders", schema: nil)

        #expect(ddl == "CREATE TABLE public.orders (id integer)")
        #expect(recorder.statements == [#"SHOW TABLE "public"."orders""#])
    }

    @Test("Without SHOW TABLE the DDL is rebuilt with its foreign keys inline")
    func reconstructionDeclaresForeignKeys() async throws {
        let recorder = CatalogReadRecorder { statement in
            if statement.hasPrefix("SHOW TABLE") { throw Refused() }
            if statement.contains("pg_catalog.pg_views") { return [] }
            if statement.contains("pg_catalog.format_type") { return [[#""id" integer NOT NULL"#].cells] }
            return []
        }
        let ddl = try await Self.catalog(recorder).fetchTableDDL(table: "orders", schema: nil)

        #expect(ddl == """
            CREATE TABLE "public"."orders" (
              "id" integer NOT NULL
            );
            """)
        #expect(RedshiftCatalogExport.tableDDLIncludesForeignKeys)
    }

    @Test("A rebuilt table with no columns read fails with the driver's message")
    func reconstructionWithoutColumnsFails() async {
        let recorder = CatalogReadRecorder { statement in
            if statement.hasPrefix("SHOW TABLE") { throw Refused() }
            return []
        }
        do {
            _ = try await Self.catalog(recorder).fetchTableDDL(table: "orders", schema: nil)
            Issue.record("Expected a failure")
        } catch {
            #expect(error.localizedDescription == "Failed to fetch DDL for table 'orders'")
        }
    }

    @Test("Local columns map the information_schema row")
    func localColumnsMap() async throws {
        let recorder = CatalogReadRecorder { _ in
            [["status", "USER-DEFINED", "NO", nil, "en_US.UTF-8", "", "mood", "YES"].cells]
        }
        let column = try #require(try await Self.catalog(recorder).fetchColumns(table: "orders", schema: nil).first)

        #expect(column.name == "status")
        #expect(column.dataType == "ENUM(mood)")
        #expect(!column.isNullable)
        #expect(column.isPrimaryKey)
        #expect(column.charset == "UTF-8")
        #expect(column.comment == nil)
    }

    @Test("An external schema's columns come from svv_external_columns of the connected database")
    func externalColumnsReadTheExternalView() async throws {
        let recorder = CatalogReadRecorder { _ in [["payload", "struct<a:int>", "true", "1"].cells] }
        let columns = try await Self.catalog(recorder, externalSchemas: ["spectrum"])
            .fetchColumns(table: "events", schema: "spectrum")

        #expect(recorder.statements == [
            RedshiftExternalSchemaQueries.listExternalColumns(schema: "spectrum", table: "events", database: "dev")
        ])
        #expect(columns.first?.dataType == "struct<a:int>")
    }

    @Test("An external table has no row count to read")
    func externalTableHasNoRowCount() async throws {
        let recorder = CatalogReadRecorder()
        let count = try await Self.catalog(recorder, externalSchemas: ["spectrum"])
            .fetchApproximateRowCount(table: "events", schema: "spectrum")

        #expect(count == nil)
        #expect(recorder.reads.isEmpty)
    }

    @Test("A negative tbl_rows is no count")
    func negativeRowCountIsNone() async throws {
        let recorder = CatalogReadRecorder { _ in [["-1"].cells] }
        #expect(try await Self.catalog(recorder).fetchApproximateRowCount(table: "orders", schema: nil) == nil)
    }
}
