//
//  ClickHouseSummaryParserTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("ClickHouseSummaryParser")
struct ClickHouseSummaryParserTests {
    @Test("Reads the elapsed nanoseconds a modern server sends")
    func readsElapsed() {
        let header = """
            {"read_rows":"1000","read_bytes":"8000","written_rows":"0","written_bytes":"0",\
            "total_rows_to_read":"1000","result_rows":"1000","result_bytes":"16000","elapsed_ns":"346699000"}
            """

        let summary = ClickHouseSummaryParser.parse(headerValue: header)

        #expect(summary?.elapsed == 0.346699)
        #expect(summary?.readRows == 1_000)
        #expect(summary?.readBytes == 8_000)
    }

    /// `elapsed_ns` only appears on servers new enough to send it, and a missing figure has to stay
    /// missing: a zero would render as a query that took no time at all.
    @Test("A server that sends no elapsed figure yields nil rather than zero")
    func missingElapsedStaysNil() {
        let header = #"{"read_rows":"5","read_bytes":"40"}"#

        let summary = ClickHouseSummaryParser.parse(headerValue: header)

        #expect(summary?.elapsed == nil)
        #expect(summary?.readRows == 5)
    }

    @Test("Header lookup ignores the case the server used")
    func headerLookupIsCaseInsensitive() {
        let summary = ClickHouseSummaryParser.parse(
            headers: ["x-clickhouse-summary": #"{"elapsed_ns":"1000000"}"#]
        )

        #expect(summary?.elapsed == 0.001)
    }

    @Test("An absent header yields nothing")
    func absentHeader() {
        #expect(ClickHouseSummaryParser.parse(headers: ["Content-Type": "text/plain"]) == nil)
    }

    @Test("A body that is not the expected object yields nothing")
    func malformedHeader() {
        #expect(ClickHouseSummaryParser.parse(headerValue: "not json") == nil)
        #expect(ClickHouseSummaryParser.parse(headerValue: "[]") == nil)
        #expect(ClickHouseSummaryParser.parse(headerValue: "{}") == nil)
    }

    @Test("Unquoted numbers are read as well, in case a server stops quoting them")
    func unquotedNumbers() {
        let summary = ClickHouseSummaryParser.parse(headerValue: #"{"elapsed_ns":2000000,"read_rows":3}"#)

        #expect(summary?.elapsed == 0.002)
        #expect(summary?.readRows == 3)
    }
}
