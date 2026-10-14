//
//  QualifiedSearchQueryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct QualifiedSearchQueryTests {
    @Test("A schema and a name")
    func schemaAndName() throws {
        let query = try #require(QualifiedSearchQuery("attendance.timesheet"))
        #expect(query.containers == ["attendance"])
        #expect(query.name == "timesheet")
    }

    @Test("A trailing dot asks for everything in the container")
    func trailingDot() throws {
        let query = try #require(QualifiedSearchQuery("attendance."))
        #expect(query.containers == ["attendance"])
        #expect(query.name.isEmpty)
    }

    @Test("A database, a schema and a name")
    func threeParts() throws {
        let query = try #require(QualifiedSearchQuery("shop.attendance.timesheet"))
        #expect(query.containers == ["shop", "attendance"])
        #expect(query.name == "timesheet")
    }

    @Test("Spaces around a dot are ignored")
    func spacesAroundDot() throws {
        let query = try #require(QualifiedSearchQuery("attendance . timesheet"))
        #expect(query.containers == ["attendance"])
        #expect(query.name == "timesheet")
    }

    @Test("Text with no dot is not qualified")
    func plainText() {
        #expect(QualifiedSearchQuery("timesheet") == nil)
        #expect(QualifiedSearchQuery("") == nil)
    }

    @Test("An empty container keeps the text an ordinary search")
    func emptyContainer() {
        #expect(QualifiedSearchQuery(".orders") == nil)
        #expect(QualifiedSearchQuery("a..b") == nil)
    }

    @Test("A dot inside quotes belongs to the name", arguments: [
        "attendance.\"time.sheet\"",
        "attendance.[time.sheet]",
        "attendance.`time.sheet`"
    ])
    func quotedDot(_ text: String) throws {
        let query = try #require(QualifiedSearchQuery(text))
        #expect(query.containers == ["attendance"])
        #expect(query.name == "time.sheet")
    }

    @Test("A quoted schema keeps its case and its dot")
    func quotedSchema() throws {
        let query = try #require(QualifiedSearchQuery("\"My.Schema\".\"TimeSheet\""))
        #expect(query.containers == ["My.Schema"])
        #expect(query.name == "TimeSheet")
    }

    @Test("A doubled closing quote is a literal quote")
    func doubledQuote() throws {
        let query = try #require(QualifiedSearchQuery("\"a\"\"b\".c"))
        #expect(query.containers == ["a\"b"])
        #expect(query.name == "c")
    }

    @Test("An unterminated quote runs to the end of the text")
    func unterminatedQuote() throws {
        let query = try #require(QualifiedSearchQuery("attendance.\"time.sh"))
        #expect(query.containers == ["attendance"])
        #expect(query.name == "time.sh")
    }

    @Test("Containers line up with a location from the right")
    func containerPairs() throws {
        let query = try #require(QualifiedSearchQuery("attendance.timesheet"))
        let pairs = try #require(query.containerPairs(with: ["shop", "attendance"]))
        #expect(pairs.map { $0.query } == ["attendance"])
        #expect(pairs.map { $0.candidate } == ["attendance"])
    }

    @Test("A query naming more containers than the location has cannot match")
    func tooManyContainers() throws {
        let query = try #require(QualifiedSearchQuery("shop.attendance.timesheet"))
        #expect(query.containerPairs(with: ["attendance"]) == nil)
    }

    @Test("A location keeps a schema named like its database as a level of its own")
    func locationKeepsBothLevels() throws {
        #expect(QualifiedSearchQuery.location(database: "shop", schema: "shop") == ["shop", "shop"])
        #expect(QualifiedSearchQuery.location(database: "shop", schema: "public") == ["shop", "public"])
        #expect(QualifiedSearchQuery.location(database: nil, schema: "public") == ["public"])
        #expect(QualifiedSearchQuery.location(database: "", schema: nil).isEmpty)

        let full = try #require(QualifiedSearchQuery("shop.shop.orders"))
        let short = try #require(QualifiedSearchQuery("shop.orders"))
        #expect(full.containerPairs(with: ["shop", "shop"]) != nil)
        #expect(short.containerPairs(with: ["shop", "shop"]) != nil)
    }
}
