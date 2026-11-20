import Foundation
import TableProPluginKit
import Testing

private let composed = "caf\u{E9}"
private let decomposed = "cafe\u{301}"
private let composedAcute = "\u{E9}"
private let decomposedAcute = "e\u{301}"

// ClickHouse compares table names by their bytes, so two names that differ only in Unicode form are two tables.
struct ClickHouseExportTwinNameTests {
    private static func tsv(_ columns: [String], _ rows: [[String]]) -> ClickHouseStubReply {
        let lines = [columns, columns.map { _ in "String" }] + rows
        return ClickHouseStubReply(statusCode: 200, body: lines.map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n")
    }

    private static func server(tables: [String]) -> ClickHouseStubServer {
        ClickHouseStubServer { request in
            if request.body.contains("FROM system.tables") {
                return tsv(["name", "primary_key", "sorting_key"], tables.map { [$0, "id", "id"] })
            }
            return tsv(
                ["table", "name", "type", "default_kind", "default_expression", "comment"],
                tables.map { [$0, "id", "UInt32", "", "", ""] }
            )
        }
    }

    @Test("The export's column read throws on two tables named alike in different Unicode forms")
    func exportColumnReadThrowsOnTwins() async throws {
        let driver = Self.server(tables: [composed, decomposed]).connectedDriver()

        await #expect(throws: PluginCatalogNameCollision.self) {
            try await driver.fetchAllColumnsForExport(schema: "vb")
        }
    }

    @Test("Without twins the export's column read sends the shared read's statements and answers alike")
    func exportColumnReadMatchesTheSharedRead() async throws {
        let shared = Self.server(tables: ["a", "b"])
        let exported = Self.server(tables: ["a", "b"])

        let sharedColumns = try await shared.connectedDriver().fetchAllColumns(schema: "vb")
        let exportColumns = try await exported.connectedDriver().fetchAllColumnsForExport(schema: "vb")

        #expect(exported.requests.map { $0.body } == shared.requests.map { $0.body })
        #expect(exported.requests.count == 2)
        #expect(exportColumns.keys.sorted() == ["a", "b"])
        #expect(exportColumns["a"]?.map { $0.isPrimaryKey } == sharedColumns["a"]?.map { $0.isPrimaryKey })
    }

    @Test("Only the key column is a key when another column of its table is named alike in another Unicode form")
    func twinColumnIsNotAKey() async throws {
        let server = ClickHouseStubServer { request in
            if request.body.contains("SELECT primary_key, sorting_key FROM system.tables") {
                return Self.tsv(["primary_key", "sorting_key"], [[composedAcute, composedAcute]])
            }
            if request.body.contains("FROM system.tables") {
                return Self.tsv(["name", "primary_key", "sorting_key"], [["t", composedAcute, composedAcute]])
            }
            if request.body.contains("SELECT table, name") {
                return Self.tsv(
                    ["table", "name", "type", "default_kind", "default_expression", "comment"],
                    [["t", composedAcute, "UInt32", "", "", ""], ["t", decomposedAcute, "UInt32", "", "", ""]]
                )
            }
            return Self.tsv(
                ["name", "type", "default_kind", "default_expression", "comment"],
                [[composedAcute, "UInt32", "", "", ""], [decomposedAcute, "UInt32", "", "", ""]]
            )
        }
        let driver = server.connectedDriver()

        let own = try await driver.fetchColumns(table: "t", schema: "vb")
        let all = try await driver.fetchAllColumnsForExport(schema: "vb")

        #expect(own.map { $0.isPrimaryKey } == [true, false])
        #expect(all["t"]?.map { $0.isPrimaryKey } == [true, false])
    }
}
