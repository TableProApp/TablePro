//
//  XLSXWriterSheetNameTests.swift
//  TableProTests
//

import Foundation
import Testing

struct XLSXWriterSheetNameTests {
    private static let fortyCharacterName = "customer_subscription_billing_events_log"

    private func addSheet(_ name: String, to writer: XLSXWriter) {
        writer.beginSheet(name: name, columns: ["id"], includeHeader: false, convertNullToEmpty: true)
        writer.finishSheet()
    }

    private func workbookSheetNames(of writer: XLSXWriter) async throws -> [String] {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await writer.write(to: destination)
        let written = try Data(contentsOf: destination)
        let archive = try #require(String(bytes: written, encoding: .isoLatin1))
        let pattern = try NSRegularExpression(pattern: #"<sheet name="([^"]*)""#)
        let range = NSRange(archive.startIndex..., in: archive)
        return pattern.matches(in: archive, range: range).compactMap { match in
            Range(match.range(at: 1), in: archive).map { String(archive[$0]) }
        }
    }

    private func areDistinctIgnoringCase(_ names: [String]) -> Bool {
        Set(names.map { $0.lowercased() }).count == names.count
    }

    @Test("Two tables with the same name get two sheet names")
    func sameNameTwiceIsNumbered() async throws {
        let writer = XLSXWriter()
        addSheet("users", to: writer)
        addSheet("users", to: writer)
        #expect(try await workbookSheetNames(of: writer) == ["users", "users (2)"])
    }

    @Test("Names that differ only in case count as the same name, as Excel compares them")
    func caseOnlyDifferenceIsNumbered() async throws {
        let writer = XLSXWriter()
        addSheet("users", to: writer)
        addSheet("Users", to: writer)
        let names = try await workbookSheetNames(of: writer)
        #expect(names == ["users", "Users (2)"])
        #expect(areDistinctIgnoringCase(names))
    }

    @Test("A number already taken by another table is skipped")
    func takenNumberIsSkipped() async throws {
        let writer = XLSXWriter()
        addSheet("users", to: writer)
        addSheet("users (2)", to: writer)
        addSheet("users", to: writer)
        #expect(try await workbookSheetNames(of: writer) == ["users", "users (2)", "users (3)"])
    }

    @Test("Two long names that share their first 31 characters get two sheet names within the limit")
    func longNamesSharingAPrefixStayDistinct() async throws {
        let writer = XLSXWriter()
        addSheet(Self.fortyCharacterName, to: writer)
        addSheet(Self.fortyCharacterName + "_archive", to: writer)
        let names = try await workbookSheetNames(of: writer)
        #expect(names.count == 2)
        #expect(names.allSatisfy { $0.count <= 31 })
        #expect(areDistinctIgnoringCase(names))
    }

    @Test("A continuation sheet of a long table keeps its number within the 31 character limit")
    func continuationOfLongNameKeepsItsSuffix() async throws {
        let writer = XLSXWriter()
        writer.beginSheet(name: Self.fortyCharacterName, columns: ["id"], includeHeader: false, convertNullToEmpty: true)
        writer.continueSheet(
            baseName: Self.fortyCharacterName,
            columns: ["id"],
            includeHeader: false,
            convertNullToEmpty: true
        )
        writer.finishSheet()
        let names = try await workbookSheetNames(of: writer)
        #expect(names.count == 2)
        #expect(names.allSatisfy { $0.count <= 31 })
        #expect(areDistinctIgnoringCase(names))
        #expect(names.last?.hasSuffix(" (2)") == true)
    }
}
