//
//  QueryResultFilesTests.swift
//  TableProTests
//

import AppIntents
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing
import UniformTypeIdentifiers

struct QueryResultFilesTests {
    @Test("Each row becomes a JSON object keyed by column, with NULL as null and bytes as Base64")
    func rowsAreObjectsKeyedByColumn() throws {
        let objects = QueryResultFiles.rowObjects(
            columns: ["id", "note", "blob"],
            rows: [[.text("1"), .null, .bytes(Data([0x01, 0x02]))], [.text("2"), .text("say \"hi\""), .null]]
        )

        #expect(objects == [
            #"{"id":"1","note":null,"blob":"AQI="}"#,
            #"{"id":"2","note":"say \"hi\"","blob":null}"#
        ])
        let decoded = try JSONSerialization.jsonObject(with: Data(objects[1].utf8)) as? [String: Any]
        #expect(decoded?["note"] as? String == "say \"hi\"")
    }

    @Test("A repeated column name gets a numbered key instead of overwriting the first")
    func repeatedColumnsKeepBothValues() {
        let objects = QueryResultFiles.rowObjects(columns: ["id", "id"], rows: [[.text("1"), .text("7")]])

        #expect(objects == [#"{"id":"1","id 2":"7"}"#])
    }

    @Test("The first value is the first column of the first row, and nothing when there is none")
    func firstValue() {
        #expect(QueryResultFiles.firstValue(rows: [[.text("42"), .text("x")], [.text("9")]]) == "42")
        #expect(QueryResultFiles.firstValue(rows: []) == nil)
        #expect(QueryResultFiles.firstValue(rows: [[.null]]) == nil)
    }

    @Test("CSV has a header row and quotes a field holding a comma, a quote or a line break")
    func csvQuotesWhatNeedsIt() {
        let csv = QueryResultFiles.csv(
            columns: ["name", "note"],
            rows: [[.text("Ada"), .text("a,b")], [.text("Grace"), .text("line\nbreak")], [.null, .text("say \"hi\"")]]
        )

        #expect(csv == "name,note\nAda,\"a,b\"\nGrace,\"line\nbreak\"\n,\"say \"\"hi\"\"\"\n")
    }

    @Test("CSV text reads back through the payload parser the insert actions use")
    func csvRoundTripsThroughThePayloadParser() throws {
        let csv = QueryResultFiles.csv(columns: ["name", "note"], rows: [[.text("Ada"), .text("a,b")]])

        let rows = try RowPayload.parseCSV(csv)

        #expect(rows == [PayloadRow(values: ["name": .text("Ada"), "note": .text("a,b")])])
    }

    @Test("Each format hands Shortcuts the files it reads as that kind of value")
    func filesPerFormat() {
        let columns = ["count"]
        let rows: [[PluginCellValue]] = [[.text("42")]]

        let rowFiles = QueryResultFiles.files(columns: columns, rows: rows, format: .rows)
        #expect(rowFiles.map(\.filename) == ["row-1.json"])
        #expect(rowFiles.first?.type == .json)
        #expect(rowFiles.first?.data == Data(#"{"count":"42"}"#.utf8))

        let value = QueryResultFiles.files(columns: columns, rows: rows, format: .firstValue)
        #expect(value.first?.data == Data("42".utf8))
        #expect(value.first?.type == .utf8PlainText)

        #expect(QueryResultFiles.files(columns: columns, rows: rows, format: .csv).first?.type == .commaSeparatedText)
        #expect(QueryResultFiles.files(columns: columns, rows: rows, format: .json).first?.data == Data(#"[{"count":"42"}]"#.utf8))
        #expect(QueryResultFiles.files(columns: columns, rows: [], format: .rows).isEmpty)
        #expect(QueryResultFiles.files(columns: columns, rows: [], format: .json).first?.data == Data("[]".utf8))
    }
}
