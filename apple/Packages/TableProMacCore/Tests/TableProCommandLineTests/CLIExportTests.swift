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
    @Test("JSON exports round-trip controls on terminals and in pipes", arguments: [1, 2])
    func jsonControls(tableCount: Int) async throws {
        let text = "\u{7F}\u{85}\u{1B}"
        let document = "[{\"value\":\"\u{7F}\u{85}\\u001b\",\"number\":12345678901234567890.1234567890}]"
        var outputs: [String] = []
        for terminal in [false, true] {
            try await withRig { rig in
                await rig.route([
                    "list_connections": try stagingListing(),
                    "export_data": try exported("json", Array(repeating: ("users", document), count: tableCount))
                ])
                let code = await rig.run(
                    ["export", "-c", "Staging", "--format", "json"] + Array(repeating: "users", count: tableCount),
                    stdoutIsTerminal: terminal
                )
                #expect(code == .success)
                let decoded = try JSONSerialization.jsonObject(with: Data(rig.console.output.utf8))
                let rows = try #require(tableCount == 1 ? decoded as? [[String: Any]] : (decoded as? [[[String: Any]]])?.first)
                #expect(rows.first?["value"] as? String == text)
                #expect(rig.console.output.contains("12345678901234567890.1234567890"))
                outputs.append(rig.console.output)
            }
        }
        #expect(outputs[0] == outputs[1])
    }
    @Test("Exports escape terminal controls and preserve them in pipes", arguments: [true, false], ["csv", "sql"])
    func exportedControls(stdoutIsTerminal: Bool, format: String) async throws {
        try await withRig { rig in
            let text = "value\n\u{1B}]52;c;eA==\u{07}\u{1B}[2J\n"
            await rig.route([
                "list_connections": try stagingListing(),
                "export_data": try exported(format, [("users", text)])
            ])
            let code = await rig.run(
                ["export", "-c", "Staging", "--format", format, "users"],
                stdoutIsTerminal: stdoutIsTerminal
            )
            #expect(code == .success)
            let expected = stdoutIsTerminal ? "value\n\\x1B]52;c;eA==\\x07\\x1B[2J\n" : text
            #expect(rig.console.output == expected)
        }
    }

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
