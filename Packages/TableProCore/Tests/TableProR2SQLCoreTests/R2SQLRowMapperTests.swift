import Foundation
import Testing
@testable import TableProR2SQLCore

@Suite("R2 SQL row mapping")
struct R2SQLRowMapperTests {
    @Test("Rows follow the schema's order and a missing key is NULL")
    func schemaOrder() {
        let result = R2SQLResult(
            schema: [R2SQLField(name: "b", typeName: "utf8"), R2SQLField(name: "a", typeName: "int64")],
            rows: [["a": .number(1), "b": .string("x")], ["a": .number(2)]]
        )
        let mapped = R2SQLRowMapper.map(result)

        #expect(mapped.columns == ["b", "a"])
        #expect(mapped.columnTypeNames == ["TEXT", "BIGINT"])
        #expect(mapped.rows == [[.text("x"), .text("1")], [.null, .text("2")]])
    }

    @Test("Wide integers and decimals keep every digit")
    func exactNumbers() throws {
        let value = try JSONDecoder().decode(R2SQLJSONValue.self, from: Data("12345678901234567.89".utf8))
        #expect(R2SQLTypeMapper.cell(value, kind: .decimal) == .text("12345678901234567.89"))
        #expect(R2SQLTypeMapper.cell(.number(Decimal(string: "18446744073709551615")!), kind: .integer)
            == .text("18446744073709551615"))
    }

    @Test("A floating-point column keeps its fractional form")
    func floatingPoint() {
        #expect(R2SQLTypeMapper.cell(.number(1), kind: .floatingPoint) == .text("1.0"))
        #expect(R2SQLTypeMapper.cell(.number(Decimal(string: "0.1")!), kind: .floatingPoint) == .text("0.1"))
    }

    @Test("A bytes column decodes base64, and text that is not base64 stays text")
    func binary() {
        #expect(R2SQLTypeMapper.cell(.string("AAEC/w=="), kind: .binary) == .bytes([0, 1, 2, 255]))
        #expect(R2SQLTypeMapper.cell(.string("not base64!"), kind: .binary) == .text("not base64!"))
        #expect(R2SQLTypeMapper.cell(.string("AAEC/w=="), kind: .text) == .text("AAEC/w=="))
    }

    @Test("JSON null is NULL and booleans read as true or false")
    func nullAndBoolean() {
        #expect(R2SQLTypeMapper.cell(.null, kind: .text) == .null)
        #expect(R2SQLTypeMapper.cell(nil, kind: .integer) == .null)
        #expect(R2SQLTypeMapper.cell(.bool(false), kind: .boolean) == .text("false"))
    }
}
