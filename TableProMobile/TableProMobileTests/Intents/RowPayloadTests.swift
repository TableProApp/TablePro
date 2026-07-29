import Foundation
import Testing
@testable import TableProMobile

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
}
