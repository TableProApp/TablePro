import Foundation
@testable import TableProInfluxDBCore
import Testing

private func bytes(_ text: String) -> Data {
    Data(text.utf8)
}

struct InfluxResponseDecoderTests {
    @Test func aNullInAOneColumnV3ResultIsAQuotedEmptyCell() {
        let table = InfluxResponseDecoder.decodeV3CSV(bytes("note\n\"\"\n\"hot, \"\"quoted\"\"\"\na;b\n"))
        #expect(table == InfluxResultTable(
            columns: ["note"],
            typeNames: [InfluxTypeName.string],
            rows: [[nil], ["hot, \"quoted\""], ["a;b"]]
        ))
    }

    @Test func aNullV3AggregateIsOneRowOfNil() {
        let table = InfluxResponseDecoder.decodeV3CSV(bytes("max(cpu.usage)\n\"\"\n"))
        #expect(table.columns == ["max(cpu.usage)"])
        #expect(table.rows == [[nil]])
    }

    @Test func anEmptyV3CellBesideOthersIsNil() {
        let table = InfluxResponseDecoder.decodeV3CSV(bytes("host,note\na,\nb,\"hot, \"\"quoted\"\"\"\nc,a;b\n"))
        #expect(table.columns == ["host", "note"])
        #expect(table.rows == [["a", nil], ["b", "hot, \"quoted\""], ["c", "a;b"]])
    }

    @Test func aZeroByteV3BodyIsEmpty() {
        #expect(InfluxResponseDecoder.decodeV3CSV(Data()) == .empty)
    }

    @Test func aV3TimestampWithoutAZoneGetsZ() {
        let csv = "time,usage\n2024-10-27T03:33:20,12.5\n2024-10-27T03:34:20.500,50.1\n2024-10-27T03:35:20Z,7.0\n"
        let table = InfluxResponseDecoder.decodeV3CSV(bytes(csv))
        #expect(table.typeNames == [InfluxTypeName.timestamp, InfluxTypeName.float])
        #expect(table.column(named: "time") == ["2024-10-27T03:33:20Z", "2024-10-27T03:34:20.500Z", "2024-10-27T03:35:20Z"])
    }

    @Test func v3ColumnTypesAreInferredFromEveryValue() {
        let csv = "i,f,b,s,mixed,u\n-3,1.5,true,s,1,18446744073709551615\n4,2,false,t,2.5,\n"
        let table = InfluxResponseDecoder.decodeV3CSV(bytes(csv))
        #expect(table.typeNames == [
            InfluxTypeName.integer,
            InfluxTypeName.float,
            InfluxTypeName.boolean,
            InfluxTypeName.string,
            InfluxTypeName.float,
            InfluxTypeName.unsigned,
        ])
        #expect(table.rows == [["-3", "1.5", "true", "s", "1", "18446744073709551615"], ["4", "2", "false", "t", "2.5", nil]])
    }

    @Test func invalidUTF8InOneV3CellKeepsTheOtherRows() {
        var body = bytes("note\nok\n")
        body.append(contentsOf: [0x61, 0xFF, 0x62, 0x0A])
        body.append(bytes("fine\n"))
        let table = InfluxResponseDecoder.decodeV3CSV(body)
        #expect(table.rows == [["ok"], ["a\u{FFFD}b"], ["fine"]])
    }

    @Test func v3CSVReadsCRLFLineEnds() {
        let table = InfluxResponseDecoder.decodeV3CSV(bytes("host,usage\r\na,1\r\nb,2\r\n"))
        #expect(table.columns == ["host", "usage"])
        #expect(table.rows == [["a", "1"], ["b", "2"]])
    }

    @Test func oneV1SeriesIsOneGrid() throws {
        let body = bytes(#"""
        {"results":[{"statement_id":0,"series":[{"name":"cpu",
          "columns":["time","host","idle","note","region","usage","zone"],
          "values":[["2024-10-27T03:35:20Z","c",10,"a;b","eu",7,"1"],["2024-10-27T03:34:20Z","b",40,"hot, \"quoted\"","us",50.1,null]]}]}]}
        """#)
        let table = try InfluxResponseDecoder.decodeV1JSON(body)
        #expect(table.columns == ["time", "host", "idle", "note", "region", "usage", "zone"])
        #expect(table.rows == [
            ["2024-10-27T03:35:20Z", "c", "10", "a;b", "eu", "7", "1"],
            ["2024-10-27T03:34:20Z", "b", "40", "hot, \"quoted\"", "us", "50.1", nil],
        ])
        #expect(table.typeNames[0] == InfluxTypeName.timestamp)
        #expect(table.typeNames[1] == InfluxTypeName.string)
        #expect(table.typeNames[2] == InfluxTypeName.integer)
    }

    @Test func v1GroupByTagsBecomeLeadingTagColumns() throws {
        let body = bytes(#"""
        {"results":[{"statement_id":0,"series":[
        {"name":"cpu","tags":{"host":"a","region":"eu"},"columns":["time","mean"],"values":[["2024-10-27T03:30:00Z",12.5]]},
        {"name":"cpu","tags":{"host":"b","region":"us"},"columns":["time","mean"],"values":[["2024-10-27T03:30:00Z",50.1]]}
        ]}]}
        """#)
        let table = try InfluxResponseDecoder.decodeV1JSON(body)
        #expect(table == InfluxResultTable(
            columns: ["host", "region", "time", "mean"],
            typeNames: [InfluxTypeName.tag, InfluxTypeName.tag, InfluxTypeName.timestamp, InfluxTypeName.float],
            rows: [
                ["a", "eu", "2024-10-27T03:30:00Z", "12.5"],
                ["b", "us", "2024-10-27T03:30:00Z", "50.1"],
            ]
        ))
    }

    @Test func v1SeriesWithDifferentNamesAddANameColumnFirst() throws {
        let body = bytes(#"""
        {"results":[
          {"statement_id":0,"series":[{"name":"cpu","columns":["time","usage"],"values":[["2024-10-27T03:33:20Z",12.5]]}]},
          {"statement_id":1,"series":[{"name":"mem","columns":["time","used"],"values":[["2024-10-27T03:33:20Z",40]]}]}]}
        """#)
        let table = try InfluxResponseDecoder.decodeV1JSON(body)
        #expect(table.columns == ["name", "time", "usage", "used"])
        #expect(table.rows == [
            ["cpu", "2024-10-27T03:33:20Z", "12.5", nil],
            ["mem", "2024-10-27T03:33:20Z", nil, "40"],
        ])
    }

    @Test func aV1SeriesNameDoesNotOverwriteAValueColumnCalledName() throws {
        let body = bytes(#"""
        {"results":[
          {"statement_id":0,"series":[{"name":"measurements","columns":["name"],"values":[["cpu"],["mem"]]}]},
          {"statement_id":1,"series":[{"name":"databases","columns":["name"],
            "values":[["legacy_db"],["_monitoring"],["_tasks"],["metrics"],["renamed"]]}]}]}
        """#)
        let table = try InfluxResponseDecoder.decodeV1JSON(body)
        #expect(table.columns.count == 2)
        #expect(table.rows == [
            ["measurements", "cpu"],
            ["measurements", "mem"],
            ["databases", "legacy_db"],
            ["databases", "_monitoring"],
            ["databases", "_tasks"],
            ["databases", "metrics"],
            ["databases", "renamed"],
        ])
    }

    @Test func aV1StatementErrorThrows() {
        let body = bytes(#"{"results":[{"statement_id":0,"error":"database not found: nope"}]}"#)
        #expect(throws: InfluxError.query("database not found: nope")) {
            try InfluxResponseDecoder.decodeV1JSON(body)
        }
    }

    @Test func aV1TopLevelErrorThrows() {
        let body = bytes(#"{"error":"query error: database not found: nope"}"#)
        #expect(throws: InfluxError.query("query error: database not found: nope")) {
            try InfluxResponseDecoder.decodeV1JSON(body)
        }
    }

    @Test(arguments: [#"{"results":[{"statement_id":0}]}"#, "{}\n"])
    func aV1BodyWithoutSeriesIsEmpty(body: String) throws {
        #expect(try InfluxResponseDecoder.decodeV1JSON(bytes(body)) == .empty)
    }

    @Test func aV1BodyThatIsNotJSONThrowsMalformedResponse() {
        #expect(throws: InfluxError.malformedResponse("not json")) {
            try InfluxResponseDecoder.decodeV1JSON(bytes("not json"))
        }
    }

    @Test func fluxTablesWithDifferentHeadersUnionTheirColumns() throws {
        let body = bytes(
            "#datatype,string,long,dateTime:RFC3339,string,double\r\n"
                + ",result,table,_time,host,_value\r\n"
                + ",_result,0,2024-10-27T03:33:20Z,a,12.5\r\n"
                + ",_result,1,2024-10-27T03:34:20Z,b,50.1\r\n"
                + "\r\n"
                + "#datatype,string,long,dateTime:RFC3339,string,long\r\n"
                + ",result,table,_time,region,count\r\n"
                + ",_result,2,2024-10-27T03:33:20Z,eu,2\r\n"
                + "\r\n"
        )
        let table = try InfluxResponseDecoder.decodeFluxCSV(body)
        #expect(table == InfluxResultTable(
            columns: ["table", "_time", "host", "_value", "region", "count"],
            typeNames: [
                InfluxTypeName.integer,
                InfluxTypeName.timestamp,
                InfluxTypeName.string,
                InfluxTypeName.float,
                InfluxTypeName.string,
                InfluxTypeName.integer,
            ],
            rows: [
                ["0", "2024-10-27T03:33:20Z", "a", "12.5", nil, nil],
                ["1", "2024-10-27T03:34:20Z", "b", "50.1", nil, nil],
                ["2", "2024-10-27T03:33:20Z", nil, nil, "eu", "2"],
            ]
        ))
    }

    @Test func aFluxErrorTableThrows() {
        let body = bytes(
            "#datatype,string,string\r\n"
                + ",error,reference\r\n"
                + ",\"runtime error @2:4-2:20: filter: type conflict\",\r\n"
                + "\r\n"
        )
        #expect(throws: InfluxError.query("runtime error @2:4-2:20: filter: type conflict")) {
            try InfluxResponseDecoder.decodeFluxCSV(body)
        }
    }

    @Test func anEmptyFluxBodyIsEmpty() throws {
        #expect(try InfluxResponseDecoder.decodeFluxCSV(bytes("\r\n")) == .empty)
    }

    @Test func schemaTypesReplaceInferredTypesByColumnName() {
        let table = InfluxResultTable(
            columns: ["time", "host", "usage", "extra"],
            typeNames: [InfluxTypeName.timestamp, InfluxTypeName.string, InfluxTypeName.integer, InfluxTypeName.string],
            rows: [["2024-10-27T03:35:20Z", "c", "7", "x"]]
        )
        let schema = [
            InfluxColumn(name: "usage", typeName: InfluxTypeName.float, role: .field),
            InfluxColumn(name: "host", typeName: InfluxTypeName.tag, role: .tag),
            InfluxColumn(name: "time", typeName: InfluxTypeName.timestamp, role: .time),
        ]
        let typed = table.typed(by: schema)
        #expect(typed.typeNames == [InfluxTypeName.timestamp, InfluxTypeName.tag, InfluxTypeName.float, InfluxTypeName.string])
        #expect(typed.rows == table.rows)
    }

    @Test(arguments: [
        (InfluxTypeName.tag, "TEXT"),
        (InfluxTypeName.string, "TEXT"),
        (InfluxTypeName.float, "DOUBLE"),
        (InfluxTypeName.integer, "BIGINT"),
        (InfluxTypeName.unsigned, "UBIGINT"),
        (InfluxTypeName.boolean, "BOOLEAN"),
        (InfluxTypeName.timestamp, "TIMESTAMP"),
    ])
    func typeNamesClassifyAsTheirSQLSpelling(typeName: String, classification: String) {
        #expect(InfluxTypeName.classificationName(for: typeName) == classification)
    }

    @Test(arguments: [
        ("Dictionary(Int32, Utf8)", InfluxTypeName.tag, InfluxColumn.Role.tag),
        ("Timestamp(Nanosecond, None)", InfluxTypeName.timestamp, .time),
        ("Timestamp(ns)", InfluxTypeName.timestamp, .time),
        ("Float64", InfluxTypeName.float, .field),
        ("Int64", InfluxTypeName.integer, .field),
        ("UInt64", InfluxTypeName.unsigned, .field),
        ("Boolean", InfluxTypeName.boolean, .field),
        ("Utf8", InfluxTypeName.string, .field),
    ])
    func v3ArrowTypesMapToInfluxTypes(arrowType: String, typeName: String, role: InfluxColumn.Role) {
        let table = InfluxResultTable(
            columns: ["column_name", "data_type"],
            typeNames: [InfluxTypeName.string, InfluxTypeName.string],
            rows: [["c", arrowType]]
        )
        #expect(InfluxSchema.v3Columns(from: table) == [InfluxColumn(name: "c", typeName: typeName, role: role)])
    }

    @Test func v3ColumnsPutTimeFirstAndTheRestByName() {
        let csv = """
        column_name,data_type
        b,Boolean
        host,"Dictionary(Int32, Utf8)"
        idle,Int64
        note,Utf8
        region,"Dictionary(Int32, Utf8)"
        time,Timestamp(ns)
        u,UInt64
        usage,Float64
        zone,"Dictionary(Int32, Utf8)"

        """
        let columns = InfluxSchema.v3Columns(from: InfluxResponseDecoder.decodeV3CSV(bytes(csv)))
        #expect(columns == [
            InfluxColumn(name: "time", typeName: InfluxTypeName.timestamp, role: .time),
            InfluxColumn(name: "b", typeName: InfluxTypeName.boolean, role: .field),
            InfluxColumn(name: "host", typeName: InfluxTypeName.tag, role: .tag),
            InfluxColumn(name: "idle", typeName: InfluxTypeName.integer, role: .field),
            InfluxColumn(name: "note", typeName: InfluxTypeName.string, role: .field),
            InfluxColumn(name: "region", typeName: InfluxTypeName.tag, role: .tag),
            InfluxColumn(name: "u", typeName: InfluxTypeName.unsigned, role: .field),
            InfluxColumn(name: "usage", typeName: InfluxTypeName.float, role: .field),
            InfluxColumn(name: "zone", typeName: InfluxTypeName.tag, role: .tag),
        ])
    }

    @Test func influxQLColumnsJoinTagAndFieldKeysWithTimeFirst() throws {
        let tagKeys = try InfluxResponseDecoder.decodeV1JSON(bytes(#"""
        {"results":[{"statement_id":0,"series":[{"name":"cpu","columns":["tagKey"],"values":[["zone"],["host"],["region"]]}]}]}
        """#))
        let fieldKeys = try InfluxResponseDecoder.decodeV1JSON(bytes(#"""
        {"results":[{"statement_id":0,"series":[{"name":"cpu","columns":["fieldKey","fieldType"],"values":[["usage","float"],["idle","integer"],["note","string"]]}]}]}
        """#))
        #expect(InfluxSchema.influxQLColumns(tagKeys: tagKeys, fieldKeys: fieldKeys) == [
            InfluxColumn(name: "time", typeName: InfluxTypeName.timestamp, role: .time),
            InfluxColumn(name: "host", typeName: InfluxTypeName.tag, role: .tag),
            InfluxColumn(name: "idle", typeName: InfluxTypeName.integer, role: .field),
            InfluxColumn(name: "note", typeName: InfluxTypeName.string, role: .field),
            InfluxColumn(name: "region", typeName: InfluxTypeName.tag, role: .tag),
            InfluxColumn(name: "usage", typeName: InfluxTypeName.float, role: .field),
            InfluxColumn(name: "zone", typeName: InfluxTypeName.tag, role: .tag),
        ])
    }

    @Test func aMappingThatIsNotTheDefaultReadsTagsOffOnePoint() throws {
        let target = InfluxQLTarget(database: "telegraf", retentionPolicy: "weekly", isDefault: false)
        #expect(InfluxSchema.measurementsStatement(generation: .v2, target: target).text
            == #"SHOW MEASUREMENTS ON "telegraf"."weekly""#)
        #expect(InfluxSchema.influxQLTagKeysStatement(measurement: "disk", target: target).text
            == #"SELECT * FROM "weekly"."disk" LIMIT 1"#)
        #expect(InfluxSchema.influxQLFieldKeysStatement(measurement: "disk", target: target).text
            == #"SHOW FIELD KEYS FROM "weekly"."disk""#)
        let point = try InfluxResponseDecoder.decodeV1JSON(bytes(#"""
        {"results":[{"statement_id":0,"series":[{"name":"disk","columns":["time","host","used"],"values":[["2024-10-27T03:33:20Z","a",1]]}]}]}
        """#))
        let fieldKeys = try InfluxResponseDecoder.decodeV1JSON(bytes(#"""
        {"results":[{"statement_id":0,"series":[{"name":"disk","columns":["fieldKey","fieldType"],"values":[["used","integer"]]}]}]}
        """#))
        #expect(InfluxSchema.influxQLColumns(tagKeys: point, fieldKeys: fieldKeys) == [
            InfluxColumn(name: "time", typeName: InfluxTypeName.timestamp, role: .time),
            InfluxColumn(name: "host", typeName: InfluxTypeName.tag, role: .tag),
            InfluxColumn(name: "used", typeName: InfluxTypeName.integer, role: .field),
        ])
    }

    @Test func aDefaultMappingKeepsShowTagKeys() {
        let target = InfluxQLTarget(database: "legacy_db", retentionPolicy: "autogen")
        #expect(InfluxSchema.influxQLTagKeysStatement(measurement: "evt", target: target).text
            == #"SHOW TAG KEYS FROM "autogen"."evt""#)
        #expect(InfluxSchema.measurementsStatement(generation: .v2).text == "SHOW MEASUREMENTS")
    }
}
