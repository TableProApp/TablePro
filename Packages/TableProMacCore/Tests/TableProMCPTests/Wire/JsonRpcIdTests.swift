import Foundation
@testable import TableProMCP
import Testing

struct JsonRpcIdTests {
    @Test func testNullRoundTrip() throws {
        let id: JsonRpcId = .null
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(JsonRpcId.self, from: data)
        #expect(decoded == .null)
    }

    @Test func testNullEncodesAsJsonNull() throws {
        let id: JsonRpcId = .null
        let data = try JSONEncoder().encode(id)
        #expect(String(data: data, encoding: .utf8) == "null")
    }

    @Test func testStringRoundTrip() throws {
        let id: JsonRpcId = .string("abc-123")
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(JsonRpcId.self, from: data)
        #expect(decoded == .string("abc-123"))
    }

    @Test func testNumberRoundTrip() throws {
        let id: JsonRpcId = .number(42)
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(JsonRpcId.self, from: data)
        #expect(decoded == .number(42))
    }

    @Test func testLargeNumberRoundTrip() throws {
        let id: JsonRpcId = .number(Int64.max)
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(JsonRpcId.self, from: data)
        #expect(decoded == .number(Int64.max))
    }

    @Test func testDecodeJsonNullProducesNullCase() throws {
        let raw = Data("null".utf8)
        let decoded = try JSONDecoder().decode(JsonRpcId.self, from: raw)
        #expect(decoded == .null)
    }

    @Test(arguments: ["true", "[1,2]", "{}"])
    func testDecodeBoolArrayOrObjectThrows(_ json: String) {
        let raw = Data(json.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(JsonRpcId.self, from: raw) }
    }

    @Test func testAsJsonValueMapsEachCase() {
        #expect(JsonRpcId.string("abc").asJsonValue == .string("abc"))
        #expect(JsonRpcId.number(42).asJsonValue == .int(42))
        #expect(JsonRpcId.null.asJsonValue == .null)
    }

    @Test func testAsJsonValueClampsOversizedNumbers() {
        #expect(JsonRpcId.number(Int64(Int.max)).asJsonValue == .int(Int.max))
        #expect(JsonRpcId.number(Int64(Int.min)).asJsonValue == .int(Int.min))
    }

    @Test func testIdsHashAndCompareByCase() {
        #expect(JsonRpcId.number(1) == .number(1))
        #expect(JsonRpcId.number(1) != JsonRpcId.string("1"))
        #expect(Set([JsonRpcId.number(1), .number(1), .string("1")]).count == 2)
    }

    @Test func testDecodeDoubleThrows() {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(JsonRpcId.self, from: Data("1.5".utf8)) }
    }
}
