//
//  LinkedSQLFavoriteWriterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Linked SQL favorite metadata rewrite")
struct LinkedSQLFavoriteWriterTests {
    private typealias Metadata = SQLFrontmatter.Metadata

    private static let annotatedFile = """
        -- @name: Monthly revenue
        -- @author: alice
        -- @reviewed: 2026-09-01
        -- @keyword: rev
        SELECT 1;

        """

    @Test("Renaming keeps every header line the app does not own, in place")
    func renameKeepsForeignLines() {
        let rewritten = LinkedSQLFavoriteWriter.rewrite(
            Self.annotatedFile,
            with: Metadata(name: "Revenue", keyword: "rev", description: nil)
        )

        #expect(rewritten == """
            -- @name: Revenue
            -- @author: alice
            -- @reviewed: 2026-09-01
            -- @keyword: rev
            SELECT 1;

            """)
    }

    @Test("Saving the metadata the file already has leaves it byte for byte")
    func unchangedMetadataIsIdentity() {
        let content = "--@Name:  Monthly revenue\n-- @ticket: T-12\n--  @keyword: rev\n\nSELECT 1;\n"

        let rewritten = LinkedSQLFavoriteWriter.rewrite(content, with: SQLFrontmatter.parse(content))

        #expect(rewritten == content)
    }

    @Test("A new key goes beside the owned keys in canonical order without moving foreign lines")
    func addedKeyFollowsCanonicalOrder() {
        let rewritten = LinkedSQLFavoriteWriter.rewrite(
            Self.annotatedFile,
            with: Metadata(name: "Monthly revenue", keyword: "rev", description: "Totals by month")
        )

        #expect(rewritten == """
            -- @name: Monthly revenue
            -- @author: alice
            -- @reviewed: 2026-09-01
            -- @keyword: rev
            -- @description: Totals by month
            SELECT 1;

            """)
    }

    @Test("A missing name is inserted before the first owned key")
    func addedNamePrecedesExistingKeyword() {
        let content = "-- @author: alice\n-- @keyword: rev\nSELECT 1;\n"

        let rewritten = LinkedSQLFavoriteWriter.rewrite(
            content,
            with: Metadata(name: "Revenue", keyword: "rev", description: nil)
        )

        #expect(rewritten == "-- @author: alice\n-- @name: Revenue\n-- @keyword: rev\nSELECT 1;\n")
    }

    @Test("Clearing a value removes only that key's line")
    func clearedValueRemovesOnlyItsLine() {
        let rewritten = LinkedSQLFavoriteWriter.rewrite(
            Self.annotatedFile,
            with: Metadata(name: "Monthly revenue", keyword: nil, description: nil)
        )

        #expect(rewritten == """
            -- @name: Monthly revenue
            -- @author: alice
            -- @reviewed: 2026-09-01
            SELECT 1;

            """)
    }

    @Test("A leading formatter directive survives adding a name")
    func formatterDirectiveSurvives() {
        let rewritten = LinkedSQLFavoriteWriter.rewrite(
            "-- @formatter:off\nSELECT 1;\n",
            with: Metadata(name: "Unformatted", keyword: nil, description: nil)
        )

        #expect(rewritten == "-- @name: Unformatted\n-- @formatter:off\nSELECT 1;\n")
    }

    @Test("A CRLF file keeps CRLF on every line, old and new")
    func crlfLineEndingsArePreserved() {
        let content = "-- @name: Old\r\n-- @ticket: T-1\r\nSELECT 1;\r\nSELECT 2;\r\n"

        let rewritten = LinkedSQLFavoriteWriter.rewrite(
            content,
            with: Metadata(name: "New", keyword: "two", description: nil)
        )

        #expect(rewritten == "-- @name: New\r\n-- @keyword: two\r\n-- @ticket: T-1\r\nSELECT 1;\r\nSELECT 2;\r\n")
    }

    @Test("A header created in a CRLF file uses CRLF")
    func createdHeaderMatchesBodyLineEnding() {
        let rewritten = LinkedSQLFavoriteWriter.rewrite(
            "SELECT 1;\r\n",
            with: Metadata(name: "One", keyword: nil, description: nil)
        )

        #expect(rewritten == "-- @name: One\r\n\r\nSELECT 1;\r\n")
    }

    @Test("A header created in a file without one is separated from the SQL by a blank line")
    func createdHeaderGetsSeparator() {
        let rewritten = LinkedSQLFavoriteWriter.rewrite(
            "SELECT 1;\n",
            with: Metadata(name: "One", keyword: "one", description: nil)
        )

        #expect(rewritten == "-- @name: One\n-- @keyword: one\n\nSELECT 1;\n")
    }

    @Test("A multi-line description is written on one header line and never reaches the SQL")
    func multiLineValueStaysInHeader() {
        let rewritten = LinkedSQLFavoriteWriter.rewrite(
            "-- @name: Revenue\nSELECT 1;\n",
            with: Metadata(name: "Revenue", keyword: nil, description: "Totals\nby month")
        )

        #expect(rewritten == "-- @name: Revenue\n-- @description: Totals by month\nSELECT 1;\n")
        #expect(SQLFrontmatter.split(rewritten).body == "SELECT 1;\n")
    }

    @Test(
        "A value holding a Unicode line separator is kept when saved unchanged",
        arguments: ["\u{0085}", "\u{2028}", "\u{2029}"]
    )
    func unicodeSeparatorSurvivesUnchangedSave(separator: String) {
        let content = "-- @name: Revenue\(separator) by month\n-- @keyword: rev\nSELECT 1;\n"

        let rewritten = LinkedSQLFavoriteWriter.rewrite(content, with: SQLFrontmatter.parse(content))

        #expect(rewritten == content)
    }

    @Test(
        "A value holding a Unicode line separator is kept when a sibling key changes",
        arguments: ["\u{0085}", "\u{2028}", "\u{2029}"]
    )
    func unicodeSeparatorSurvivesSiblingChange(separator: String) {
        let content = "-- @name: Revenue\(separator) by month\n-- @keyword: rev\nSELECT 1;\n"
        let name = SQLFrontmatter.parse(content).name

        let rewritten = LinkedSQLFavoriteWriter.rewrite(
            content,
            with: Metadata(name: name, keyword: "revenue", description: nil)
        )

        #expect(rewritten == "-- @name: Revenue\(separator) by month\n-- @keyword: revenue\nSELECT 1;\n")
    }

    @Test(
        "A new value holding a Unicode line separator is written as typed and reads back",
        arguments: ["\u{0085}", "\u{2028}", "\u{2029}"]
    )
    func unicodeSeparatorInNewValueReadsBack(separator: String) {
        let metadata = Metadata(name: "Revenue\(separator) by month", keyword: "rev", description: nil)

        let rewritten = LinkedSQLFavoriteWriter.rewrite("-- @name: Old\n-- @keyword: rev\nSELECT 1;\n", with: metadata)

        #expect(rewritten == "-- @name: Revenue\(separator) by month\n-- @keyword: rev\nSELECT 1;\n")
        #expect(SQLFrontmatter.parse(rewritten) == metadata)
    }

    @Test("A duplicated owned key collapses to one line and keeps the foreign line between")
    func duplicatedOwnedKeyCollapses() {
        let rewritten = LinkedSQLFavoriteWriter.rewrite(
            "-- @name: First\n-- @owner: data\n-- @name: Second\nSELECT 1;\n",
            with: Metadata(name: "Third", keyword: nil, description: nil)
        )

        #expect(rewritten == "-- @name: Third\n-- @owner: data\nSELECT 1;\n")
    }

    @Test("Clearing every owned key leaves the foreign lines and the SQL untouched")
    func clearingEverythingKeepsForeignLines() {
        let rewritten = LinkedSQLFavoriteWriter.rewrite(
            Self.annotatedFile,
            with: Metadata(name: nil, keyword: nil, description: nil)
        )

        #expect(rewritten == "-- @author: alice\n-- @reviewed: 2026-09-01\nSELECT 1;\n")
    }

    @Test("The rewritten header reads back as the metadata that was saved")
    func rewrittenHeaderParsesBack() {
        let metadata = Metadata(name: "Revenue", keyword: "rev", description: "Totals")

        let rewritten = LinkedSQLFavoriteWriter.rewrite(Self.annotatedFile, with: metadata)

        #expect(SQLFrontmatter.parse(rewritten) == metadata)
    }

    @Test("Writing metadata to a file on disk keeps its foreign lines and line endings")
    func writeMetadataKeepsFileBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("linked-favorite-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = "-- @name: Old\r\n-- @author: alice\r\n-- @ticket: T-7\r\nSELECT 1;\r\n"
        try Data(original.utf8).write(to: url)

        try LinkedSQLFavoriteWriter.writeMetadata(
            Metadata(name: "New", keyword: nil, description: nil),
            to: url
        )

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written == "-- @name: New\r\n-- @author: alice\r\n-- @ticket: T-7\r\nSELECT 1;\r\n")
    }

    @Test("Changing the keyword of an 8-bit file keeps every byte of its name line")
    func writeMetadataKeepsEightBitNameBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("linked-favorite-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: url) }
        let nameLine = Data("-- @name: Revenue".utf8) + Data([0x85]) + Data(" by month\n".utf8)
        try (nameLine + Data("-- @keyword: rev\nSELECT 1;\n".utf8)).write(to: url)
        let loaded = try #require(FileTextLoader.load(url))
        let name = SQLFrontmatter.parse(loaded.content).name

        try LinkedSQLFavoriteWriter.writeMetadata(
            Metadata(name: name, keyword: "revenue", description: nil),
            to: url
        )

        let written = try Data(contentsOf: url)
        #expect(written == nameLine + Data("-- @keyword: revenue\nSELECT 1;\n".utf8))
    }

    @Test(
        "Editing a file's metadata keeps its encoding, byte order mark and encoding attribute",
        arguments: EncodedSQLFileFixture.allCases
    )
    func writeMetadataKeepsTheFileEncoding(fixture: EncodedSQLFileFixture) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("linked-favorite-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture.write("-- @name: Old\n" + fixture.original, to: url)

        try LinkedSQLFavoriteWriter.writeMetadata(
            Metadata(name: "New", keyword: "kw", description: nil),
            to: url
        )

        let expected = try #require(fixture.bytes(of: "-- @name: New\n-- @keyword: kw\n" + fixture.original))
        #expect(try Data(contentsOf: url) == expected)
        #expect(EncodedSQLFileFixture.attributeValue(of: url) == fixture.attributeValue)
        let reloaded = try #require(FileTextLoader.load(url))
        #expect(reloaded.encoding == fixture.reportedEncoding)
        #expect(SQLFrontmatter.parse(reloaded.content) == Metadata(name: "New", keyword: "kw", description: nil))
    }

    @Test("Metadata the file's encoding cannot hold is refused with that encoding and the file is left alone")
    func writeMetadataRefusesUnrepresentableText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("linked-favorite-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = EncodedSQLFileFixture.windowsCyrillicByAttribute
        try fixture.write("-- @name: Old\n" + fixture.original, to: url)
        let before = try Data(contentsOf: url)

        do {
            try LinkedSQLFavoriteWriter.writeMetadata(
                Metadata(name: "\u{1F600}", keyword: nil, description: nil),
                to: url
            )
            Issue.record("A name the file's encoding cannot hold was written")
        } catch LinkedSQLFavoriteWriter.WriteError.encodingMismatch(let encoding) {
            #expect(encoding.encoding == .windowsCP1251)
            #expect(encoding.displayName == String.localizedName(of: .windowsCP1251))
        }

        #expect(try Data(contentsOf: url) == before)
        #expect(EncodedSQLFileFixture.attributeValue(of: url) == fixture.attributeValue)
    }
}
