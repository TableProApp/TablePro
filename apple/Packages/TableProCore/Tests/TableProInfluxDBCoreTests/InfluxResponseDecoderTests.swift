import Foundation
@testable import TableProInfluxDBCore
import Testing

struct InfluxResponseDecoderTests {
    @Test func v3CSVKeepsStatementColumnOrderAndReadsEmptyAsNull() {
        let csv = "usage,host,note,time\n12.5,a,,2024-10-27T03:33:20\n50.1,b,hot,2024-10-27T03:34:20\n"
        let table = InfluxResponseDecoder.decodeV3CSV(csv)
        #expect(table.columns == ["usage", "host", "note", "time"])
        #expect(table.typeNames == ["float", "string", "string", "timestamp"])
        #expect(table.rows[0] == ["12.5", "a", nil, "2024-10-27T03:33:20Z"])
        #expect(table.rows[1][2] == "hot")
    }

    @Test func v3CSVReadsQuotedFieldsWithCommasQuotesAndNewlines() {
        let csv = "name,note\r\nx,\"a, \"\"b\"\"\nc\"\r\n"
        let table = InfluxResponseDecoder.decodeV3CSV(csv)
        #expect(table.rows == [["x", "a, \"b\"\nc"]])
    }

    @Test func v3CSVInfersIntegerAndKeepsZonedTimestamps() {
        let table = InfluxResponseDecoder.decodeV3CSV("idle,time\n80,2024-10-27T03:33:20.5+07:00\n")
        #expect(table.typeNames == ["integer", "timestamp"])
        #expect(table.rows[0][1] == "2024-10-27T03:33:20.5+07:00")
    }

    @Test func emptyV3BodyIsAnEmptyTable() {
        #expect(InfluxResponseDecoder.decodeV3CSV("") == .empty)
    }

    @Test func v1JSONFlattensOneSeries() throws {
        let json = """
        {"results":[{"statement_id":0,"series":[{"name":"cpu","columns":["time","host","idle","note","usage"],\
        "values":[["2024-10-27T03:34:20Z","b",40,"hot",50.1],["2024-10-27T03:33:20Z","a",80,null,12.5]]}]}]}
        """
        let table = try InfluxResponseDecoder.decodeV1JSON(Data(json.utf8))
        #expect(table.columns == ["time", "host", "idle", "note", "usage"])
        #expect(table.typeNames == ["timestamp", "string", "integer", "string", "float"])
        #expect(table.rows[1] == ["2024-10-27T03:33:20Z", "a", "80", nil, "12.5"])
    }

    @Test func v1JSONPutsGroupTagsAndVaryingNamesFirst() throws {
        let json = """
        {"results":[{"statement_id":0,"series":[\
        {"name":"cpu","tags":{"host":"a"},"columns":["time","mean"],"values":[["t1",1.5]]},\
        {"name":"mem","tags":{"host":"b"},"columns":["time","mean"],"values":[["t1",true]]}]}]}
        """
        let table = try InfluxResponseDecoder.decodeV1JSON(Data(json.utf8))
        #expect(table.columns == ["name", "host", "time", "mean"])
        #expect(table.typeNames[1] == "tag")
        #expect(table.rows == [["cpu", "a", "t1", "1.5"], ["mem", "b", "t1", "true"]])
    }

    @Test func v1JSONStatementErrorThrows() {
        let json = #"{"results":[{"statement_id":0,"error":"measurement not found"}]}"#
        #expect(throws: InfluxError.query("measurement not found")) {
            try InfluxResponseDecoder.decodeV1JSON(Data(json.utf8))
        }
    }

    @Test func fluxCSVUnionsTableHeadersAndDropsAnnotationColumns() throws {
        let csv = """
        #datatype,string,long,dateTime:RFC3339,string,long,double
        ,result,table,_time,host,idle,usage
        ,_result,0,2024-10-27T03:33:20Z,a,80,12.5

        #datatype,string,long,dateTime:RFC3339,string,long,string
        ,result,table,_time,host,idle,note
        ,_result,1,2024-10-27T03:34:20Z,b,40,hot

        """
        let table = try InfluxResponseDecoder.decodeFluxCSV(csv)
        #expect(table.columns == ["table", "_time", "host", "idle", "usage", "note"])
        #expect(table.typeNames == ["integer", "timestamp", "string", "integer", "float", "string"])
        #expect(table.rows == [
            ["0", "2024-10-27T03:33:20Z", "a", "80", "12.5", nil],
            ["1", "2024-10-27T03:34:20Z", "b", "40", nil, "hot"],
        ])
    }

    @Test func fluxErrorTableThrows() {
        let csv = "#datatype,string,string\n,error,reference\n,\"runtime error: boom\",\n"
        #expect(throws: InfluxError.query("runtime error: boom")) {
            try InfluxResponseDecoder.decodeFluxCSV(csv)
        }
    }

    @Test func errorMessagePrefersMessageThenErrorThenText() {
        #expect(InfluxResponseDecoder.errorMessage(from: Data(#"{"code":"invalid","message":"bad"}"#.utf8)) == "bad")
        #expect(InfluxResponseDecoder.errorMessage(from: Data(#"{"error":"nope"}"#.utf8)) == "nope")
        #expect(InfluxResponseDecoder.errorMessage(from: Data("SQL error: x\n".utf8)) == "SQL error: x")
    }
}
