import TableProTrinoCore
import Testing

struct TrinoTypeTextTests {
    private func column(_ type: String) -> TrinoColumnSpec {
        TrinoColumnSpec(name: "info", type: type, nullable: true, comment: nil)
    }

    // Trino reports a row field name bare in `data_type` and in a result's column type, whatever the name holds.
    @Test("Type text that leaves the type is not written", arguments: [
        "row(x integer)); DROP TABLE lake.default.orders; SELECT (1 -- integer)",
        "row(x integer)) WHERE false; UPDATE lake.default.orders SET total = 0 WHERE id = 1; -- integer)",
        #"row(x integer)), "id" = 0 WHERE true -- integer)"#,
        #"row(x integer), "id" = (0 integer)"#,
        "",
    ])
    func typeThatLeavesTheTypeIsNotWritten(type: String) {
        #expect(TrinoDDLSQL.columnDefinition(column(type)) == nil)
        #expect(TrinoDDLSQL.createTable(
            qualifiedTable: "t", columns: [column("integer"), column(type)], tableComment: nil, ifNotExists: false
        ) == nil)
        #expect(TrinoDDLSQL.addColumn(qualifiedTable: "t", column: column(type)) == nil)
        #expect(TrinoDDLSQL.setColumnType(qualifiedTable: "t", name: "info", type: type) == nil)
    }

    @Test("A structured value is not cast to type text that leaves the type", arguments: [
        "row(x integer)); DROP TABLE lake.default.orders; SELECT (1 -- integer)",
        "row(x integer)) WHERE false; UPDATE lake.default.orders SET total = 0 WHERE id = 1; -- integer)",
        #"row(x integer)), "id" = 0 WHERE true -- integer)"#,
    ])
    func structuredValueIsNotCastToEscapingType(type: String) {
        let value = TrinoColumnValue(name: "info", value: .text("[2]"), typeName: type)
        #expect(TrinoLiteral.render(.text("[2]"), typeName: type) == nil)
        #expect(value.sql == nil)
        #expect(TrinoRowEditSQL.insert(qualifiedTable: "t", columns: [value]) == nil)
        let key = TrinoColumnValue(name: "id", value: .text("1"), typeName: "integer")
        #expect(TrinoRowEditSQL.update(qualifiedTable: "t", assignments: [value], keyColumns: [key]) == nil)
    }

    @Test("A type as Trino reports one is written as it is", arguments: [
        "integer",
        "decimal(10,2)",
        "varchar(255)",
        "timestamp(3) with time zone",
        "interval day to second",
        "array(varchar(10))",
        "map(varchar, bigint)",
        "row(x integer, y array(varchar(10)))",
        #"row("a b" integer)"#,
    ])
    func typeIsWritten(type: String) {
        #expect(TrinoDDLSQL.columnDefinition(column(type)) == "\"info\" \(type)")
        #expect(TrinoDDLSQL.addColumn(qualifiedTable: "t", column: column(type)) == "ALTER TABLE t ADD COLUMN \"info\" \(type)")
        #expect(
            TrinoDDLSQL.setColumnType(qualifiedTable: "t", name: "info", type: type)
                == "ALTER TABLE t ALTER COLUMN \"info\" SET DATA TYPE \(type)"
        )
    }

    @Test("A structured value is cast to its column's type")
    func structuredValueIsCast() {
        #expect(TrinoLiteral.render(.text("[1]"), typeName: "row(x integer)") == "CAST(json_parse('[1]') AS row(x integer))")
    }

    // Trino reads only ASCII digits as a number, so anything else bare would be a name or an error.
    @Test("A number column takes only ASCII digits bare", arguments: ["\u{0661}\u{0662}", "1\u{0301}", "\u{FF11}", "\u{00BD}"])
    func nonASCIIDigitsAreQuoted(text: String) {
        #expect(TrinoLiteral.render(.text(text), typeName: "integer") == "'\(text)'")
    }

    @Test("An ASCII number is written bare")
    func asciiNumberIsBare() {
        #expect(TrinoLiteral.render(.text("-12.5e3"), typeName: "double") == "-12.5e3")
        #expect(TrinoLiteral.render(.text("1e"), typeName: "double") == "'1e'")
    }
}
