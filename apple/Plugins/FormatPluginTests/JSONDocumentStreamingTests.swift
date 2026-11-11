//
//  JSONDocumentStreamingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

private func writeJSON(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("json-document-\(UUID().uuidString).json")
    try data.write(to: url)
    return url
}

private func writeJSON(_ text: String) throws -> URL {
    try writeJSON(Data(text.utf8))
}

private func drain(_ elements: any JSONElementSequence) throws -> [Any] {
    var elements = elements
    defer { elements.close() }
    var values: [Any] = []
    while let element = try elements.next() {
        values.append(element)
    }
    return values
}

struct JSONDocumentStreamingTests {
    private static let trickyRows = [
        #"{"id":1,"name":"Ada \"the\" {first} [one]","path":"C:\\temp\\","tags":["a","]","}"],"meta":{"k":[1,{"x":null}]}}"#,
        #"{"id":9007199254740993,"score":-3.9192320754595876e-07,"ok":true,"none":null,"city":"Hà Nội 東京 \u00e9"}"#,
        #"{"note":"line\nbreak \u2028 sep","empty":"","nested":[[[]]],"obj":{}}"#,
        #"{}"#,
    ]

    private func streamedRows(_ url: URL, targetTable: String? = nil, chunkSize: Int) throws -> [Any] {
        var reader = try JSONDocumentReader(url: url, chunkSize: chunkSize)
        let rows = try JSONDocumentOutline.rows(in: &reader, targetTable: targetTable) { reader, _ in
            try reader.skipValue()
        }
        guard case .array(let offset, let count, _) = rows else {
            reader.close()
            Issue.record("Expected the rows of an array, got \(rows)")
            return []
        }
        let values = try drain(JSONStreamedElements(reader: reader, arrayAt: offset))
        #expect(values.count == count)
        return values
    }

    private func importedElements(_ json: String, targetTable: String? = nil) throws -> [Any] {
        let url = try writeJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }
        return try drain(JSONImportParsing.rowElements(at: url, targetTable: targetTable, checkCancellation: {}).elements)
    }

    private func parsedElements(_ json: String, targetTable: String? = nil) throws -> [Any] {
        let url = try writeJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }
        return try JSONImportParsing.parseElements(at: url, targetTable: targetTable)
    }

    @Test("Elements read one at a time equal a whole-file parse, whatever the chunk size", arguments: [1, 3, 64, 1 << 20])
    func streamedElementsMatchAWholeFileParse(chunkSize: Int) throws {
        let array = "[\n  " + Self.trickyRows.joined(separator: ",\n  ") + "\n]"
        let wrapped = #"{"public.other":[{"x":1}], "public.people" : "# + array + "}"
        for (json, target) in [(array, nil), (wrapped, "people")] as [(String, String?)] {
            let url = try writeJSON(json)
            defer { try? FileManager.default.removeItem(at: url) }
            let expected = try JSONImportParsing.parseElements(at: url, targetTable: target)
            let streamed = try streamedRows(url, targetTable: target, chunkSize: chunkSize)
            #expect((streamed as NSArray).isEqual(to: expected))
        }
    }

    @Test("The reader holds one chunk and one element, not the file")
    func readerHoldsOneChunkAndOneElement() throws {
        let rows = (1...5_000).map { #"{"id":\#($0),"name":"value \#($0)","pad":"\#(String(repeating: "x", count: 50))"}"# }
        let json = #"{"public.t":["# + rows.joined(separator: ",") + "]}"
        let url = try writeJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }
        let chunkSize = 256
        let longestElement = rows.map(\.utf8.count).max() ?? 0

        var reader = try JSONDocumentReader(url: url, chunkSize: chunkSize)
        let layout = try JSONDocumentOutline.rows(in: &reader, targetTable: "t") { reader, _ in try reader.skipValue() }
        var mostHeld = reader.heldByteCount
        guard case .array(let offset, let count, _) = layout else {
            Issue.record("Expected the rows of an array, got \(layout)")
            return
        }
        var elements = try JSONStreamedElements(reader: reader, arrayAt: offset)
        defer { elements.close() }
        var read = 0
        while try elements.next() != nil {
            read += 1
            mostHeld = max(mostHeld, elements.heldByteCount)
        }

        #expect(count == 5_000)
        #expect(read == 5_000)
        #expect(mostHeld <= chunkSize + longestElement)
        #expect(json.utf8.count > 100 * (chunkSize + longestElement))
    }

    @Test("Every shape a whole-file parse accepts gives the same rows", arguments: [
        (#"[{"a":1},{"a":2}]"#, nil),
        (#"  [ ]  "#, nil),
        (#"[{"a":1}, 5, [1], "s", {"a":2}]"#, nil),
        (#"{"users":[{"id":1}]}"#, nil),
        (#"{"users":[{"id":1}],"orders":[{"id":1},{"id":2}]}"#, "orders"),
        (#"{"public.users":[{"id":1}]}"#, "users"),
        (#"{"id":1,"tags":["a"]}"#, nil),
        (#"{}"#, nil),
        (#"{"t":[]}"#, nil),
        (#"{"t":[{"a":1}],"t":[{"a":2},{"a":3}]}"#, nil),
        (#"{"t":5,"t":[{"a":1}]}"#, nil),
        (#"{"x":[{"a":1}],"y":[1]}"#, nil),
        (#"[{"a":1},]"#, nil),
        (#"{"t":[{"a":1} , ],}"#, nil),
    ] as [(String, String?)])
    func shapesMatchAWholeFileParse(json: String, targetTable: String?) throws {
        let imported = try importedElements(json, targetTable: targetTable)
        #expect((imported as NSArray).isEqual(to: try parsedElements(json, targetTable: targetTable)))
    }

    // A whole-file parse hands the tables over as a dictionary, whose order changes from launch to launch.
    @Test("Two tables that both match the target table resolve to the first in the file", arguments: [
        #"{"a.users":[{"n":1}],"b.users":[{"n":2}]}"#,
        #"{"Users":[{"n":1}],"users":[{"n":2}]}"#,
    ])
    func ambiguousTableResolvesToTheFirst(json: String) throws {
        let elements = try importedElements(json, targetTable: "USERS")
        #expect((elements as NSArray).isEqual(to: [["n": 1]]))
    }

    @Test("A file whose structure breaks fails before its first row", arguments: [
        #"[{"a":1},{"a":2},{"a":"#,
        #"{"t":[{"a":1}]"#,
        #"[{"a":1}] x"#,
        #"[{"a":1} {"a":2}]"#,
        #"[{"a":1},,{"a":2}]"#,
        #"[,]"#,
        #"[{"a":1]"#,
        #"{"a" 1}"#,
        "42",
        "",
    ])
    func brokenStructureFailsUpFront(json: String) throws {
        let url = try writeJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) {
            _ = try JSONImportParsing.rowElements(at: url, targetTable: nil, checkCancellation: {})
        }
    }

    @Test("A UTF-16 file still reads, through JSONSerialization's own decoding")
    func utf16FileStillReads() throws {
        let url = try writeJSON(try #require(#"{"t":[{"name":"Ada"},{"name":"Grace"}]}"#.data(using: .utf16)))
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try JSONImportParsing.rowElements(at: url, targetTable: nil, checkCancellation: {})
        #expect(document.count == 2)
        #expect((try drain(document.elements) as NSArray).isEqual(to: [["name": "Ada"], ["name": "Grace"]]))
        #expect(try JSONImportParsing.detectFields(at: url, targetTable: nil).map(\.name) == ["name"])
    }

    @Test("A file that starts with a UTF-8 byte order mark streams")
    func byteOrderMarkIsSkipped() throws {
        let url = try writeJSON(Data([0xEF, 0xBB, 0xBF]) + Data(#"[{"a":1}]"#.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect((try streamedRows(url, chunkSize: 2) as NSArray).isEqual(to: [["a": 1]]))
    }

    @Test("Detection fails on a value that does not parse, in any table, as a whole-file parse did")
    func detectionValidatesEveryTable() throws {
        let url = try writeJSON(#"{"users":[{"id":1}],"orders":[{"id":tru}]}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) {
            _ = try JSONImportParsing.detectFields(at: url, targetTable: "users")
        }
    }

    @Test("Detection reports the fields of the first of two tables with one name")
    func detectionUsesTheFirstOfTwoTablesWithOneName() throws {
        let url = try writeJSON(#"{"t":[{"a":1}],"t":[{"b":2}]}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try JSONImportParsing.detectFields(at: url, targetTable: nil).map(\.name) == ["a"])
    }
}

private final class RecordingSink: PluginImportDataSink, @unchecked Sendable {
    let databaseTypeId = "mock"
    let targetTable: String?

    private(set) var rows: [[String: PluginCellValue]] = []

    init(targetTable: String?) {
        self.targetTable = targetTable
    }

    func execute(statement: String) async throws {}
    func insertRow(_ values: [String: PluginCellValue]) async throws { rows.append(values) }
    func insertRows(_ rows: [[String: PluginCellValue]]) async throws { self.rows.append(contentsOf: rows) }
    func deleteAllRowsFromTargetTable() async throws {}
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
    func disableForeignKeyChecks() async throws {}
    func enableForeignKeyChecks() async throws {}
}

private final class DocumentSource: PluginImportSource, @unchecked Sendable {
    private let url: URL

    init(url: URL) { self.url = url }

    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fileURL() -> URL { url }
    func fileSizeBytes() -> Int64 { 0 }
}

// Serialized because `JSONImportPlugin.settings` persists through plugin storage.
@Suite(.serialized)
struct JSONDocumentImportTests {
    private func runImport(
        _ json: String,
        errorHandling: ImportErrorHandling,
        sink: RecordingSink,
        progress: PluginImportProgress = PluginImportProgress(progress: Progress())
    ) async throws -> Result<PluginImportResult, any Error> {
        let url = try writeJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }

        // `settings` persists, so the developer's own preference is put back.
        let plugin = JSONImportPlugin()
        let original = plugin.settings
        defer { plugin.settings = original }
        plugin.settings.errorHandling = errorHandling
        plugin.settings.wrapInTransaction = true
        plugin.settings.deleteExistingRows = false

        do {
            return .success(try await plugin.performImport(source: DocumentSource(url: url), sink: sink, progress: progress))
        } catch {
            return .failure(error)
        }
    }

    @Test("An array element that is not an object is reported as a skipped row, not left out unseen")
    func nonObjectElementIsReported() async throws {
        let sink = RecordingSink(targetTable: "people")
        let outcome = try await runImport(
            #"[{"name":"Ada"}, 5, ["x"], {"name":"Grace"}]"#, errorHandling: .skipAndContinue, sink: sink
        )
        guard case .success(let result) = outcome else {
            Issue.record("Skip and Continue must not abort the import: \(outcome)")
            return
        }
        #expect(result.executedStatements == 2)
        #expect(result.skippedStatements == 2)
        #expect(result.errors.map { $0.line } == [2, 3])
        #expect(sink.rows.compactMap { $0["name"] } == [.text("Ada"), .text("Grace")])
    }

    @Test("A stop mode fails on an array element that is not an object")
    func nonObjectElementStopsAStopMode() async throws {
        let outcome = try await runImport(
            #"[{"name":"Ada"}, [1, "Grace"]]"#, errorHandling: .stopAndRollback, sink: RecordingSink(targetTable: "people")
        )
        guard case .failure = outcome else {
            Issue.record("Stop and Rollback must not import a file with a row it cannot read")
            return
        }
    }

    // A whole-file parse refused such a file outright, so no error mode passes over the element.
    @Test(
        "An element that does not parse fails the import in every error mode",
        arguments: [ImportErrorHandling.skipAndContinue, .stopAndRollback, .stopAndCommit]
    )
    func unreadableElementFailsTheImport(errorHandling: ImportErrorHandling) async throws {
        let sink = RecordingSink(targetTable: "people")
        let outcome = try await runImport(
            #"[{"name":"Ada"}, {"name":tru}, {"name":"Grace"}]"#, errorHandling: errorHandling, sink: sink
        )
        guard case .failure = outcome else {
            Issue.record("An element that does not parse must fail the import: \(outcome)")
            return
        }
        #expect(sink.rows.isEmpty)
    }

    @Test("A truncated export imports nothing, even in Skip and Continue")
    func truncatedFileImportsNothing() async throws {
        let sink = RecordingSink(targetTable: "people")
        let outcome = try await runImport(
            #"{"public.people":[{"name":"Ada"},{"name":"Grace"},{"name":"Ka"#, errorHandling: .skipAndContinue, sink: sink
        )
        guard case .failure = outcome else {
            Issue.record("A truncated file must fail: \(outcome)")
            return
        }
        #expect(sink.rows.isEmpty)
    }

    @Test("A table-keyed export imports the target table's rows in file order, with an exact progress total")
    func tableKeyedExportImportsTheTargetTable() async throws {
        let sink = RecordingSink(targetTable: "people")
        let progress = PluginImportProgress(progress: Progress())
        let json = #"{"public.other":[{"name":"x"}],"public.people":[{"name":"Ada"},{"name":"Grace"},{"name":"Hedy"}]}"#
        let outcome = try await runImport(json, errorHandling: .stopAndRollback, sink: sink, progress: progress)
        guard case .success(let result) = outcome else {
            Issue.record("A valid file must import: \(outcome)")
            return
        }
        #expect(result.executedStatements == 3)
        #expect(progress.estimatedTotalStatements == 3)
        #expect(sink.rows.compactMap { $0["name"] } == [.text("Ada"), .text("Grace"), .text("Hedy")])
    }
}
