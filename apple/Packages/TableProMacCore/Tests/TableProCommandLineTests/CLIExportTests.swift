import Foundation
@testable import TableProCommandLine
import TableProMCP
import TableProMCPTestSupport
import Testing

private func exported(_ format: String, _ documents: [(label: String, data: String)]) throws -> MockHttpResponse {
    try success(.object([
        "format": .string(format),
        "rows_exported": .int(documents.count),
        "is_truncated": .bool(false),
        "exports": .array(documents.map { document in
            .object([
                "label": .string(document.label),
                "row_count": .int(1),
                "is_truncated": .bool(false),
                "data": .string(document.data)
            ])
        })
    ]))
}

struct CLIExportTests {
    @Test("Two tables in JSON print one document: an array holding each table's array, in order")
    func severalJsonTablesAreOneDocument() async throws {
        try await withRig { rig in
            await rig.route([
                "list_connections": try stagingListing(),
                "export_data": try exported("json", [("users", #"[{"id":1}]"#), ("orders", "[]")])
            ])
            #expect(await rig.run(["export", "-c", "Staging", "--format", "json", "users", "orders"]) == .success)

            let document = try JSONSerialization.jsonObject(with: Data(rig.console.output.utf8))
            let tables = try #require(document as? [[[String: Any]]])
            #expect(tables.count == 2)
            #expect(tables[0].first?["id"] as? Int == 1)
            #expect(tables[1].isEmpty)
        }
    }

    @Test("One table in JSON prints that table's array as it came")
    func oneJsonTableStaysAnArray() async throws {
        try await withRig { rig in
            await rig.route([
                "list_connections": try stagingListing(),
                "export_data": try exported("json", [("users", #"[{"id":1}]"#)])
            ])
            #expect(await rig.run(["export", "-c", "Staging", "--format", "json", "users"]) == .success)
            #expect(rig.console.output == "[{\"id\":1}]\n")
        }
    }

    @Test("Several CSV tables stay separate, with a blank line between them")
    func severalCsvTablesStayApart() async throws {
        try await withRig { rig in
            await rig.route([
                "list_connections": try stagingListing(),
                "export_data": try exported("csv", [("users", "id\n1\n"), ("orders", "id\n2")])
            ])
            #expect(await rig.run(["export", "-c", "Staging", "--format", "csv", "users", "orders"]) == .success)
            #expect(rig.console.output == "id\n1\n\nid\n2\n")
        }
    }
}
