import Foundation
@testable import TableProInfluxDBCore
import Testing

private func bytes(_ text: String) -> Data {
    Data(text.utf8)
}

private func pieces(_ data: Data, size: Int) -> [Data] {
    stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0 ..< min($0 + size, data.count)) }
}

private func records(_ chunks: [Data]) -> [[String]] {
    var reader = InfluxCSV.Reader()
    var records: [[String]] = []
    for chunk in chunks {
        reader.read(chunk)
        records += reader.drain()
    }
    return records + reader.finish()
}

private func streamed(
    _ body: InfluxGridStream.Body,
    _ chunks: [Data],
    grid: InfluxGridQuery = cpuExport,
    schema: [InfluxColumn] = cpuSchema
) throws -> [InfluxResultTable] {
    var stream = InfluxGridStream(body: body, grid: grid, schema: schema)
    var batches: [InfluxResultTable] = []
    for chunk in chunks {
        batches += try stream.consume(chunk)
    }
    let rest = try stream.finish()
    return batches + rest
}

// The batches under the header the first one carries, which every other one repeats.
private func joined(_ batches: [InfluxResultTable]) throws -> InfluxResultTable {
    let first = try #require(batches.first)
    #expect(batches.allSatisfy { $0.columns == first.columns && $0.typeNames == first.typeNames })
    return InfluxResultTable(columns: first.columns, typeNames: first.typeNames, rows: batches.flatMap { $0.rows })
}

private let cpuExport = InfluxGridQuery(measurement: "cpu", shape: .all)

private let cpuSchema = [
    InfluxColumn(name: "time", typeName: InfluxTypeName.timestamp, role: .time),
    InfluxColumn(name: "host", typeName: InfluxTypeName.tag, role: .tag),
    InfluxColumn(name: "idle", typeName: InfluxTypeName.integer, role: .field),
    InfluxColumn(name: "note", typeName: InfluxTypeName.string, role: .field),
    InfluxColumn(name: "usage", typeName: InfluxTypeName.float, role: .field),
]

private let v3Body = bytes(
    "host,time,usage,note,idle\r\n"
        + "a,2024-10-27T03:33:20,12.5,\"hot, \"\"quoted\"\"\",10\r\n"
        + "b,2024-10-27T03:34:20.500Z,,,\r\n"
        + ",2024-10-27T03:35:20,7,\"two\r\nlines é\",40\r\n"
)

private let v2Rows = [
    #"["2024-10-27T03:35:20Z","c",10,"a;b",7]"#,
    #"["2024-10-27T03:34:20Z","b",40,"hot, \"quoted\"",50.1]"#,
    #"["2024-10-27T03:33:20Z","a",null,null,12.5]"#,
]

private func v2Chunk(_ rows: ArraySlice<String>, partial: Bool) -> String {
    let flag = partial ? #","partial":true"# : ""
    return #"{"results":[{"statement_id":0,"series":[{"name":"cpu","columns":["time","host","idle","note","usage"],"values":["#
        + rows.joined(separator: ",") + "]" + flag + "}]" + flag + "}]}"
}

private let tooWide = InfluxError.malformedResponse(
    String(localized: "the result has far more columns than its rows fill")
)

struct InfluxGridStreamTests {
    @Test func aCREndingOneChunkAndTheLFStartingTheNextAreOneLineEnd() {
        #expect(records([bytes("a,b\r"), bytes("\nc,d\r\n")]) == [["a", "b"], ["c", "d"]])
    }

    @Test func anEscapedQuoteSplitBetweenItsTwoQuotesIsOneQuote() {
        #expect(records([bytes("\"x\""), bytes("\"y\",z\n")]) == [["x\"y", "z"]])
    }

    @Test func aQuotedLineEndSplitAcrossChunksStaysInTheField() {
        #expect(records([bytes("\"a\r"), bytes("\nb\",c\n"), bytes("\"d\n"), bytes("e\"\n")]) == [["a\r\nb", "c"], ["d\ne"]])
    }

    @Test("Every chunk size reads the records one whole body gives", arguments: [1, 2, 3, 7, 64])
    func chunkSizeDoesNotChangeTheRecords(size: Int) {
        var body = bytes("host,note\r\na,\"x, \"\"y\"\"\"\r\n\r\nb,\"two\nlines\"\nc,日本\r\"\"\"\",é\r\n")
        body.append(contentsOf: [0x61, 0xFF, 0x62, 0x2C, 0x7A])
        #expect(InfluxCSV.records(body) == [
            ["host", "note"],
            ["a", "x, \"y\""],
            [""],
            ["b", "two\nlines"],
            ["c", "日本"],
            ["\"", "é"],
            ["a\u{FFFD}b", "z"],
        ])
        #expect(records(pieces(body, size: size)) == InfluxCSV.records(body))
    }

    @Test("A v3 stream reads the rows and types the collected read gives", arguments: [1, 3, 64, 100_000])
    func aV3StreamReadsLikeTheCollectedRead(size: Int) throws {
        let collected = try InfluxResponseDecoder.decodeV3CSV(v3Body).typed(by: cpuSchema)
        let table = try joined(streamed(.csv, pieces(v3Body, size: size)))
        #expect(table == collected)
        #expect(table.typeNames == [
            InfluxTypeName.tag, InfluxTypeName.timestamp, InfluxTypeName.float, InfluxTypeName.string, InfluxTypeName.integer,
        ])
        #expect(table.column(named: "time") == ["2024-10-27T03:33:20Z", "2024-10-27T03:34:20.500Z", "2024-10-27T03:35:20Z"])
    }

    @Test func aV3StreamSendsBatchesOfFiveThousandRows() throws {
        let body = bytes("host,usage\n" + String(repeating: "a,1\n", count: 12_001))
        let batches = try streamed(.csv, [body])
        #expect(batches.map { $0.rows.count } == [5_000, 5_000, 2_001])
        #expect(try joined(batches).typeNames == [InfluxTypeName.tag, InfluxTypeName.float])
    }

    @Test func aWideV3HeaderShrinksTheBatchToAboutAMillionCells() throws {
        let columns = (0 ..< 4_096).map { "c\($0)" }
        let record = Array(repeating: "1", count: columns.count).joined(separator: ",")
        let body = bytes(columns.joined(separator: ",") + "\n" + String(repeating: record + "\n", count: 257))
        let batches = try streamed(.csv, [body], schema: [])
        #expect(batches.map { $0.rows.count } == [256, 1])
    }

    @Test("A v3 header of 40,000 columns over 1,000 empty records is refused, as the collected read refuses it")
    func shortV3RecordsUnderAWideHeaderAreRefused() {
        let header = (0 ..< 40_000).map { "c\($0)" }.joined(separator: ",")
        let body = bytes(header + "\n" + String(repeating: "\n", count: 1_000))
        #expect(throws: tooWide) { try streamed(.csv, [body], schema: []) }
    }

    @Test func aV3HeaderRecordWithNoRowsKeepsItsColumns() throws {
        let body = bytes("usage,time,extra\n")
        let batches = try streamed(.csv, [body])
        #expect(batches == [InfluxResultTable(
            columns: ["usage", "time", "extra"],
            typeNames: [InfluxTypeName.float, InfluxTypeName.timestamp, InfluxTypeName.string],
            rows: []
        )])
        let collected = try InfluxResponseDecoder.decodeV3CSV(body).typed(by: cpuSchema)
        #expect(batches == [collected])
    }

    @Test func aV3ColumnTheSchemaLacksIsTypedFromTheFirstBatch() throws {
        let table = try joined(streamed(.csv, [bytes("time,extra\n2024-10-27T03:33:20Z,1\n2024-10-27T03:34:20Z,2\n")]))
        #expect(table.typeNames == [InfluxTypeName.timestamp, InfluxTypeName.integer])
    }

    @Test("An empty body gets the header from the schema", arguments: [InfluxGridStream.Body.csv, .influxQLChunks])
    func anEmptyBodyGetsTheHeaderFromTheSchema(body: InfluxGridStream.Body) throws {
        let empty = body == .csv ? Data() : bytes(#"{"results":[{"statement_id":0}]}"# + "\n")
        #expect(try streamed(body, [empty]) == [InfluxResultTable(
            columns: ["time", "host", "idle", "note", "usage"],
            typeNames: [
                InfluxTypeName.timestamp, InfluxTypeName.tag, InfluxTypeName.integer, InfluxTypeName.string, InfluxTypeName.float,
            ],
            rows: []
        )])
        let page = InfluxGridQuery(measurement: "cpu", projection: ["usage", "time", "gone"], shape: .page(limit: 50, offset: 0))
        #expect(try streamed(body, [empty], grid: page) == [InfluxResultTable(
            columns: ["usage", "time", "gone"],
            typeNames: [InfluxTypeName.float, InfluxTypeName.timestamp, InfluxTypeName.string],
            rows: []
        )])
    }

    @Test("v2 chunks read the rows and types one collected body gives", arguments: [1, 5, 64, 100_000])
    func v2ChunksReadLikeTheCollectedBody(size: Int) throws {
        let collected = try InfluxResponseDecoder.decodeV1JSON(bytes(v2Chunk(v2Rows[...], partial: false)))
            .typed(by: cpuSchema)
        let body = bytes(v2Chunk(v2Rows[..<2], partial: true) + "\n" + v2Chunk(v2Rows[2...], partial: false) + "\n")
        let batches = try streamed(.influxQLChunks, pieces(body, size: size))
        #expect(batches.map { $0.rows.count } == [2, 1])
        #expect(try joined(batches) == collected)
        #expect(collected.typeNames == [
            InfluxTypeName.timestamp, InfluxTypeName.tag, InfluxTypeName.integer, InfluxTypeName.string, InfluxTypeName.float,
        ])
    }

    @Test func aLastV2ChunkWithoutItsNewlineIsStillRead() throws {
        let batches = try streamed(.influxQLChunks, [bytes(v2Chunk(v2Rows[...], partial: false))])
        #expect(batches.map { $0.rows.count } == [3])
    }

    @Test(
        "An error object after some rows throws",
        arguments: [
            #"{"results":[{"statement_id":0,"error":"max-select-point limit exceeded"}]}"#,
            #"{"error":"max-select-point limit exceeded"}"#,
        ]
    )
    func anErrorObjectAfterSomeRowsThrows(errorLine: String) throws {
        var stream = InfluxGridStream(body: .influxQLChunks, grid: cpuExport, schema: cpuSchema)
        let first = try stream.consume(bytes(v2Chunk(v2Rows[..<2], partial: true) + "\n"))
        #expect(first.map { $0.rows.count } == [2])
        #expect(throws: InfluxError.query("max-select-point limit exceeded")) {
            try stream.consume(bytes(errorLine + "\n"))
        }
    }

    @Test func aLaterV2ChunkWithItsColumnsReorderedMapsThemByName() throws {
        let later = #"{"results":[{"statement_id":0,"series":[{"name":"cpu","columns":["usage","time"],"values":[[1.5,"2024-10-27T03:30:00Z"]]}]}]}"#
        let body = bytes(v2Chunk(v2Rows[..<1], partial: true) + "\n" + later + "\n")
        let table = try joined(streamed(.influxQLChunks, [body]))
        #expect(table.rows.last == ["2024-10-27T03:30:00Z", nil, nil, nil, "1.5"])
    }

    @Test func aLaterV2ChunkWithAColumnTheFirstLacksThrows() {
        let later = #"{"results":[{"statement_id":0,"series":[{"name":"cpu","columns":["time","extra"],"values":[["2024-10-27T03:30:00Z",1]]}]}]}"#
        let body = bytes(v2Chunk(v2Rows[..<1], partial: true) + "\n" + later + "\n")
        let refusal = InfluxError.malformedResponse(
            String(format: String(localized: "column %@ first appears in a later chunk"), "extra")
        )
        #expect(throws: refusal) { try streamed(.influxQLChunks, [body]) }
    }
}
