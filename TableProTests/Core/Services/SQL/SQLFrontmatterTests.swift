//
//  SQLFrontmatterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct SQLFrontmatterTests {
    @Test("Split keeps each header line's own text and line ending")
    func splitKeepsRawHeaderLines() {
        let document = SQLFrontmatter.split("--@Name:  Revenue\r\n  -- @author: alice\n-- @x:1\rSELECT 1;\n")

        #expect(document.header.map(\.text) == ["--@Name:  Revenue", "  -- @author: alice", "-- @x:1"])
        #expect(document.header.map(\.terminator) == ["\r\n", "\n", "\r"])
        #expect(document.header.map(\.key) == ["name", "author", "x"])
        #expect(document.header.map(\.ownedKey) == [.name, nil, nil])
        #expect(document.body == "SELECT 1;\n")
    }

    @Test("The header ends at the first line that is not a key line")
    func headerStopsAtBlankLine() {
        let document = SQLFrontmatter.split("-- @name: Revenue\n\n-- @author: alice\nSELECT 1;")

        #expect(document.header.map(\.key) == ["name"])
        #expect(document.body == "\n-- @author: alice\nSELECT 1;")
    }

    @Test("A header line at the end of the file has no terminator")
    func lastHeaderLineWithoutTerminator() {
        let document = SQLFrontmatter.split("-- @name: Revenue")

        #expect(document.header.map(\.terminator) == [""])
        #expect(document.body.isEmpty)
    }

    @Test("A byte order mark is kept apart from the header")
    func byteOrderMarkIsSeparated() {
        let document = SQLFrontmatter.split("\u{FEFF}-- @name: Revenue\nSELECT 1;")

        #expect(document.byteOrderMark == "\u{FEFF}")
        #expect(document.header.map(\.text) == ["-- @name: Revenue"])
    }

    @Test("Owned keys are read past foreign ones, and the last duplicate wins")
    func parseReadsOwnedKeysAmongForeignOnes() {
        let metadata = SQLFrontmatter.parse(
            "-- @formatter:off\n-- @name: First\n-- @author: alice\n-- @name: Second\n-- @keyword:\nSELECT 1;"
        )

        #expect(metadata == SQLFrontmatter.Metadata(name: "Second", keyword: nil, description: nil))
    }
}
