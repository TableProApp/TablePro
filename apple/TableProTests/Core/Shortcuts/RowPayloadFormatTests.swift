//
//  RowPayloadFormatTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct RowPayloadFormatTests {
    // SQL Server exports its headers bracketed, so a valid CSV opens with `[`.
    @Test("CSV with bracketed headers is read as CSV")
    func bracketedHeaderIsCSV() async throws {
        let rows = try await RowPayload.parse(data: "[id],[name]\n1,Bob\n", file: nil)
        #expect(rows == [PayloadRow(values: ["[id]": .text("1"), "[name]": .text("Bob")])])
    }

    @Test("CSV whose first header opens with a brace is read as CSV")
    func braceHeaderIsCSV() async throws {
        let rows = try await RowPayload.parse(data: "{key},value\na,1\n", file: nil)
        #expect(rows == [PayloadRow(values: ["{key}": .text("a"), "value": .text("1")])])
    }

    @Test("A JSON object and a JSON array of objects are still read as JSON")
    func jsonStaysJSON() async throws {
        let object = try await RowPayload.parse(data: #"{"name":"Ada"}"#, file: nil)
        #expect(object == [PayloadRow(values: ["name": .text("Ada")])])
        let array = try await RowPayload.parse(data: #"[{"name":"Ada"},{"name":"Grace"}]"#, file: nil)
        #expect(array.count == 2)
    }

    @Test("Malformed JSON that is no CSV either reports the JSON error")
    func malformedJSONKeepsItsError() async {
        await #expect {
            _ = try await RowPayload.parse(data: #"{"name": tru}"#, file: nil)
        } throws: { error in
            guard case .malformedPayload = error as? IntentDataError else { return false }
            return true
        }
    }

    // Each line splits into the same number of CSV fields, so the text read as CSV with `{"id": 1` for a header.
    @Test("JSON with a trailing comma after each line's object keeps the JSON error")
    func jsonThatSplitsEvenlyKeepsItsError() async {
        await #expect {
            _ = try await RowPayload.parse(data: "{\"id\": 1, \"name\": \"a\"},\n{\"id\": 2, \"name\": \"b\"},\n", file: nil)
        } throws: { error in
            guard case .malformedPayload = error as? IntentDataError else { return false }
            return true
        }
    }

    @Test("A JSON array of something other than objects keeps its own error")
    func jsonArrayOfValuesIsNotRetriedAsCSV() async {
        await #expect(throws: IntentDataError.jsonArrayContainsNonObject) {
            _ = try await RowPayload.parse(data: "[1,2]", file: nil)
        }
    }
}
