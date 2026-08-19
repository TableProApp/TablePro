//
//  DatabaseDateParserTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("DatabaseDateParser")
struct DatabaseDateParserTests {
    private static let utc = TimeZone(secondsFromGMT: 0)

    @Test("Reads the spellings MySQL, PostgreSQL, SQLite and SQL Server put on the wire")
    func readsEveryWireSpelling() throws {
        let parser = DatabaseDateParser()
        let spellings = [
            "2024-03-01 12:00:00",
            "2024-03-01T12:00:00",
            "2024-03-01T12:00:00Z",
            "2024-03-01T12:00:00+0700",
            "2024-03-01T12:00:00+07:00",
            "2024-03-01T12:00:00.123Z",
            "2024-03-01 12:00:00+07",
            "2024-03-01 12:00:00+07:00",
            "2024-03-01 12:00:00.123456",
            "2024-03-01 12:00:00.123456+07",
            "2024-03-01 12:00:00.5",
            "2024-03-01",
            "12:00:00",
        ]

        for spelling in spellings {
            #expect(parser.date(from: spelling) != nil, "\(spelling) should parse")
        }
    }

    @Test("A space-separated offset is read as the instant it names, like the ISO spelling")
    func spaceSeparatedOffsetMatchesIsoSpelling() throws {
        let parser = DatabaseDateParser()
        let iso = try #require(parser.date(from: "2024-03-01T12:00:00+07:00"))
        let spaced = try #require(parser.date(from: "2024-03-01 12:00:00+07:00"))
        let shortOffset = try #require(parser.date(from: "2024-03-01 12:00:00+07"))

        #expect(iso == spaced)
        #expect(iso == shortOffset)
    }

    @Test("A value with no offset is read in the reader's own time zone")
    func naiveValuesStayLocal() throws {
        let parser = DatabaseDateParser()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parsed = try #require(parser.date(from: "2024-03-01 12:00:00"))

        #expect(calendar.component(.hour, from: parsed) == 12)
        #expect(calendar.component(.day, from: parsed) == 1)
    }

    @Test("Text that is not a date stays unparsed rather than becoming a plausible one")
    func rejectsNonDates() {
        let parser = DatabaseDateParser()

        #expect(parser.date(from: "not a date") == nil)
        #expect(parser.date(from: "") == nil)
        #expect(parser.date(from: "2024-03-01 12:00:00 trailing") == nil)
        #expect(parser.date(from: "42") == nil)
    }

    @Test("Reuses the last winning pattern without getting stuck on it")
    func alternatingSpellingsBothParse() throws {
        let parser = DatabaseDateParser()

        for _ in 0 ..< 3 {
            #expect(parser.date(from: "2024-03-01 12:00:00") != nil)
            #expect(parser.date(from: "2024-03-01") != nil)
            #expect(parser.date(from: "2024-03-01T12:00:00Z") != nil)
        }
    }
}
