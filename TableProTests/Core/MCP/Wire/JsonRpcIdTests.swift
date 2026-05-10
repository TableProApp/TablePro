import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class JsonRpcIdTests: XCTestCase {
    func testNullRoundTrip() throws {
        let id: JsonRpcId = .null
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(JsonRpcId.self, from: data)
        XCTAssertEqual(decoded, .null)
    }

    func testNullEncodesAsJsonNull() throws {
        let id: JsonRpcId = .null
        let data = try JSONEncoder().encode(id)
        XCTAssertEqual(String(data: data, encoding: .utf8), "null")
    }

    func testStringRoundTrip() throws {
        let id: JsonRpcId = .string("abc-123")
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(JsonRpcId.self, from: data)
        XCTAssertEqual(decoded, .string("abc-123"))
    }

    func testNumberRoundTrip() throws {
        let id: JsonRpcId = .number(42)
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(JsonRpcId.self, from: data)
        XCTAssertEqual(decoded, .number(42))
    }

    func testLargeNumberRoundTrip() throws {
        let id: JsonRpcId = .number(Int64.max)
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(JsonRpcId.self, from: data)
        XCTAssertEqual(decoded, .number(Int64.max))
    }

    func testDecodeJsonNullProducesNullCase() throws {
        let raw = Data("null".utf8)
        let decoded = try JSONDecoder().decode(JsonRpcId.self, from: raw)
        XCTAssertEqual(decoded, .null)
    }

    func testDecodeBoolThrows() {
        let raw = Data("true".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(JsonRpcId.self, from: raw))
    }

    func testDecodeArrayThrows() {
        let raw = Data("[1,2]".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(JsonRpcId.self, from: raw))
    }

    func testDecodeObjectThrows() {
        let raw = Data("{}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(JsonRpcId.self, from: raw))
    }
}
