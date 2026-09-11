import Testing
@testable import TableProR2SQLCore

@Suite("R2 SQL type names")
struct R2SQLTypeMapperTests {
    @Test("Result schema type names map to SQL names the grid classifies", arguments: [
        ("int64", "BIGINT", R2SQLValueKind.integer),
        ("uint64", "BIGINT UNSIGNED", .integer),
        ("int32", "INT", .integer),
        ("float64", "DOUBLE", .floatingPoint),
        ("decimal128", "DECIMAL", .decimal),
        ("bool", "BOOLEAN", .boolean),
        ("utf8", "TEXT", .text),
        ("bytes", "BINARY", .binary),
        ("date32", "DATE", .text),
        ("timestamp", "TIMESTAMP", .text),
        ("list", "ARRAY", .nested),
        ("struct", "STRUCT", .nested),
        ("map", "MAP", .nested),
        ("Int64", "BIGINT", .integer)
    ])
    func knownTypes(raw: String, display: String, kind: R2SQLValueKind) {
        #expect(R2SQLTypeMapper.displayTypeName(raw) == display)
        #expect(R2SQLTypeMapper.valueKind(raw) == kind)
    }

    @Test("An unknown type name passes through uppercased and reads as text")
    func unknownType() {
        #expect(R2SQLTypeMapper.displayTypeName("interval") == "INTERVAL")
        #expect(R2SQLTypeMapper.valueKind("interval") == .text)
    }
}
