import Foundation
import Testing

@testable import TableProSpannerCore

@Suite("SpannerPartialResultAssembler")
struct SpannerPartialResultAssemblerTests {
    private static func metadata(_ names: [String]) -> SpannerResultSetMetadata {
        SpannerResultSetMetadata(fields: names.map { SpannerField(name: $0, type: SpannerType(code: "STRING")) })
    }

    @Test("Values are cut into rows of the field count across messages")
    func rowCutting() throws {
        var assembler = SpannerPartialResultAssembler()
        let first = try assembler.consume(SpannerPartialResultSet(
            metadata: Self.metadata(["a", "b"]),
            values: [.string("1"), .string("x"), .string("2")]
        ))
        #expect(first == [[.string("1"), .string("x")]])
        let second = try assembler.consume(SpannerPartialResultSet(values: [.string("y")]))
        #expect(second == [[.string("2"), .string("y")]])
        try assembler.finish()
        #expect(assembler.metadata?.fields.count == 2)
    }

    @Test("A chunked string is concatenated with the first value of the next message")
    func chunkedString() throws {
        var assembler = SpannerPartialResultAssembler()
        let first = try assembler.consume(SpannerPartialResultSet(
            metadata: Self.metadata(["id", "s"]),
            values: [.string("1"), .string("hel")],
            chunkedValue: true
        ))
        #expect(first.isEmpty)
        let second = try assembler.consume(SpannerPartialResultSet(values: [.string("lo"), .string("2"), .string("z")]))
        #expect(second == [[.string("1"), .string("hello")], [.string("2"), .string("z")]])
        try assembler.finish()
    }

    @Test("A value chunked across three messages is merged each time")
    func threeWayString() throws {
        var assembler = SpannerPartialResultAssembler()
        _ = try assembler.consume(SpannerPartialResultSet(metadata: Self.metadata(["s"]), values: [.string("a")], chunkedValue: true))
        _ = try assembler.consume(SpannerPartialResultSet(values: [.string("b")], chunkedValue: true))
        let rows = try assembler.consume(SpannerPartialResultSet(values: [.string("c")]))
        #expect(rows == [[.string("abc")]])
    }

    @Test("The emulator's chunked array whose last element is a partial string merges element-wise")
    func emulatorArrayShape() throws {
        var assembler = SpannerPartialResultAssembler()
        var rows = try assembler.consume(SpannerPartialResultSet(
            metadata: Self.metadata(["id", "arr", "s2", "tail"]),
            values: [.string("1"), .list([.string("aaaa"), .string("b")])],
            chunkedValue: true
        ))
        rows += try assembler.consume(SpannerPartialResultSet(
            values: [.list([.string("bbb"), .string("cc")])],
            chunkedValue: true
        ))
        rows += try assembler.consume(SpannerPartialResultSet(
            values: [.list([.string("cc")]), .string("zz")],
            chunkedValue: true
        ))
        rows += try assembler.consume(SpannerPartialResultSet(values: [.string("zz"), .string("7")]))
        #expect(rows == [[
            .string("1"),
            .list([.string("aaaa"), .string("bbbb"), .string("cccc")]),
            .string("zzzz"),
            .string("7")
        ]])
        try assembler.finish()
    }

    @Test("Lists whose boundary elements are not chunkable are concatenated")
    func nonChunkableBoundary() throws {
        let merged = try SpannerPartialResultAssembler.merge(
            .list([.number(2), .number(3)]),
            .list([.number(4)])
        )
        #expect(merged == .list([.number(2), .number(3), .number(4)]))
        let mixed = try SpannerPartialResultAssembler.merge(.list([.string("a")]), .list([.null, .string("b")]))
        #expect(mixed == .list([.string("a"), .null, .string("b")]))
    }

    @Test("Nested lists merge recursively at the boundary")
    func nestedLists() throws {
        let merged = try SpannerPartialResultAssembler.merge(
            .list([.string("a"), .list([.string("b"), .string("c")])]),
            .list([.list([.string("d")]), .string("e")])
        )
        #expect(merged == .list([.string("a"), .list([.string("b"), .string("cd")]), .string("e")]))
    }

    @Test("An empty list on either side merges to the other")
    func emptyListMerge() throws {
        #expect(try SpannerPartialResultAssembler.merge(.list([]), .list([.string("a")])) == .list([.string("a")]))
        #expect(try SpannerPartialResultAssembler.merge(.list([.string("a")]), .list([])) == .list([.string("a")]))
    }

    @Test("Merging values that cannot be chunked throws", arguments: [
        (SpannerJSONValue.number(1), SpannerJSONValue.number(2)),
        (.bool(true), .bool(false)),
        (.string("a"), .list([])),
        (.null, .string("a")),
        (.object([:]), .object([:]))
    ])
    func unmergeable(head: SpannerJSONValue, tail: SpannerJSONValue) {
        #expect(throws: SpannerTransportError.invalidResponse) {
            try SpannerPartialResultAssembler.merge(head, tail)
        }
    }

    @Test("A chunk still pending at the end fails the stream")
    func pendingAtFinish() throws {
        var assembler = SpannerPartialResultAssembler()
        _ = try assembler.consume(SpannerPartialResultSet(metadata: Self.metadata(["s"]), values: [.string("a")], chunkedValue: true))
        #expect(throws: SpannerTransportError.invalidResponse) {
            try assembler.finish()
        }
    }

    @Test("Values that do not fill a whole row fail the stream")
    func partialRowAtFinish() throws {
        var assembler = SpannerPartialResultAssembler()
        _ = try assembler.consume(SpannerPartialResultSet(metadata: Self.metadata(["a", "b"]), values: [.string("1")]))
        #expect(throws: SpannerTransportError.invalidResponse) {
            try assembler.finish()
        }
    }

    @Test("A result with no fields yields no rows and keeps its stats")
    func noFields() throws {
        var assembler = SpannerPartialResultAssembler()
        let rows = try assembler.consume(SpannerPartialResultSet(
            metadata: SpannerResultSetMetadata(fields: []),
            values: [],
            stats: SpannerResultSetStats(rowCountExact: 4)
        ))
        #expect(rows.isEmpty)
        #expect(assembler.stats?.rowCountExact == 4)
        try assembler.finish()
    }

    @Test("A chunked message with no values is invalid")
    func chunkedWithoutValues() {
        var assembler = SpannerPartialResultAssembler()
        #expect(throws: SpannerTransportError.invalidResponse) {
            _ = try assembler.consume(SpannerPartialResultSet(metadata: Self.metadata(["s"]), values: [], chunkedValue: true))
        }
    }
}
