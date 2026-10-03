import Foundation
@testable import TableProMobile
import Testing

@Suite("RowPayload")
struct RowPayloadTests {
    @Test("parses a JSON object into one row")
    func jsonObject() async throws {
        let rows = try await RowPayload.parse(data: #"{"name":"Ada","age":36}"#, file: nil)
        #expect(rows.count == 1)
        #expect(rows[0].value(for: "name") == .text("Ada"))
        #expect(rows[0].value(for: "age") == .text("36"))
    }

    @Test("maps JSON null to a null value")
    func jsonNull() async throws {
        let rows = try await RowPayload.parse(data: #"{"note":null}"#, file: nil)
        #expect(rows[0].value(for: "note") == .null)
    }

    @Test("maps JSON booleans to text")
    func jsonBool() async throws {
        let rows = try await RowPayload.parse(data: #"{"active":true,"deleted":false}"#, file: nil)
        #expect(rows[0].value(for: "active") == .text("true"))
        #expect(rows[0].value(for: "deleted") == .text("false"))
    }

    @Test("parses a JSON array into multiple rows")
    func jsonArray() async throws {
        let rows = try await RowPayload.parse(data: #"[{"a":"1"},{"a":"2"}]"#, file: nil)
        #expect(rows.count == 2)
        #expect(rows[0].value(for: "a") == .text("1"))
        #expect(rows[1].value(for: "a") == .text("2"))
    }

    @Test("parses CSV with a header row")
    func csv() async throws {
        let rows = try await RowPayload.parse(data: "name,age\nAda,36\nGrace,40", file: nil)
        #expect(rows.count == 2)
        #expect(rows[0].value(for: "name") == .text("Ada"))
        #expect(rows[1].value(for: "age") == .text("40"))
    }

    @Test("handles quoted CSV fields with commas")
    func csvQuoted() async throws {
        let rows = try await RowPayload.parse(data: "label,note\n\"a,b\",\"says \"\"hi\"\"\"", file: nil)
        #expect(rows[0].value(for: "label") == .text("a,b"))
        #expect(rows[0].value(for: "note") == .text("says \"hi\""))
    }

    @Test("parses CSV with CRLF line endings")
    func csvCRLF() async throws {
        let rows = try await RowPayload.parse(data: "name,age\r\nAda,36\r\n", file: nil)
        #expect(rows.count == 1)
        #expect(rows[0].value(for: "name") == .text("Ada"))
        #expect(rows[0].value(for: "age") == .text("36"))
    }

    @Test("keeps a CRLF inside a quoted CSV field")
    func csvQuotedCRLF() async throws {
        let rows = try await RowPayload.parse(data: "name,note\r\nAda,\"first\r\nsecond\"\r\nGrace,plain\r\n", file: nil)
        #expect(rows.count == 2)
        #expect(rows[0].value(for: "note") == .text("first\r\nsecond"))
        #expect(rows[1].value(for: "name") == .text("Grace"))
        #expect(rows[1].value(for: "note") == .text("plain"))
    }

    @Test("parses CSV with carriage return line endings")
    func csvCarriageReturn() async throws {
        let rows = try await RowPayload.parse(data: "name,age\rAda,36\rGrace,40", file: nil)
        #expect(rows.count == 2)
        #expect(rows[0].value(for: "name") == .text("Ada"))
        #expect(rows[1].value(for: "age") == .text("40"))
    }

    @Test("splits a CSV field that starts with a combining mark")
    func csvCombiningMarkAfterDelimiter() async throws {
        let rows = try await RowPayload.parse(data: "name,mark\nAda,\u{0301}x", file: nil)
        #expect(rows.count == 1)
        #expect(rows[0].value(for: "name") == .text("Ada"))
        #expect(rows[0].value(for: "mark") == .text("\u{0301}x"))
    }

    @Test("parseSingle rejects multiple rows")
    func parseSingleRejectsMany() async throws {
        await #expect(throws: IntentDataError.self) {
            _ = try await RowPayload.parseSingle(data: #"[{"a":"1"},{"a":"2"}]"#, file: nil)
        }
    }

    @Test("empty input throws")
    func emptyThrows() async throws {
        await #expect(throws: IntentDataError.self) {
            _ = try await RowPayload.parse(data: "   ", file: nil)
        }
    }

    @Test("malformed JSON throws")
    func malformedJsonThrows() async throws {
        await #expect(throws: IntentDataError.self) {
            _ = try await RowPayload.parse(data: "{not valid", file: nil)
        }
    }

    @Test("rejects a JSON array containing a non-object")
    func jsonArrayRejectsNonObject() {
        #expect(throws: IntentDataError.jsonArrayContainsNonObject) {
            _ = try RowPayload.parseJSON(#"[{"a":"1"}, 2]"#)
        }
    }

    @Test("rejects a JSON value that is not an object or array")
    func jsonRejectsUnsupportedShape() {
        #expect(throws: IntentDataError.invalidJSONShape) {
            _ = try RowPayload.parseJSON("42")
        }
    }

    @Test("rejects CSV without a header")
    func csvRejectsMissingHeader() {
        #expect(throws: IntentDataError.csvMissingHeader) {
            _ = try RowPayload.parseCSV(",\nAda,36")
        }
    }

    @Test("reads a Shift JIS CSV file as its Japanese text")
    func shiftJISFile() throws {
        let csv = "氏名,住所\n山田太郎,東京都港区芝公園\n鈴木花子,大阪市北区梅田\n"
        let data = try #require(csv.data(using: .shiftJIS))
        #expect(try RowPayload.text(of: data) == csv)
    }

    @Test("reads a UTF-16 file and drops a UTF-8 byte order mark")
    func markedFiles() throws {
        let csv = "name,city\nAda,London\n"
        let utf16 = Data([0xFF, 0xFE]) + (try #require(csv.data(using: .utf16LittleEndian)))
        #expect(try RowPayload.text(of: utf16) == csv)
        #expect(try RowPayload.text(of: Data([0xEF, 0xBB, 0xBF]) + Data(csv.utf8)) == csv)
    }

    @Test("names the line a file cannot be read at")
    func unreadableLine() throws {
        let data = Data("name,city\nJürgen,Köln\nZoë,Paris\n".utf8) + Data([0x43, 0x61, 0x66, 0xE9, 0x0A])
        #expect(throws: IntentDataError.unreadableText(line: 4, encoding: "UTF-8")) {
            _ = try RowPayload.text(of: data)
        }
    }
}
