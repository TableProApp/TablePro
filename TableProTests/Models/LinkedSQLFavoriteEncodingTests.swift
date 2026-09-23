//
//  LinkedSQLFavoriteEncodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Linked SQL favorite encoding")
struct LinkedSQLFavoriteEncodingTests {
    private func favorite(encodedAs encodingName: String) -> LinkedSQLFavorite {
        LinkedSQLFavorite(
            folderId: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/report.sql"),
            relativePath: "report.sql",
            name: "report",
            mtime: Date(),
            fileSize: 8,
            encodingName: encodingName
        )
    }

    @Test("Only an encoding that cannot store every character is flagged")
    func flagsOnlyEncodingsThatLackCharacters() {
        let cases: [(encodingName: String, isFlagged: Bool)] = [
            ("utf-8", false),
            ("utf-16", false),
            ("utf-16be", false),
            ("utf-32", false),
            ("gb18030", false),
            ("iso-8859-1", true),
            ("cp932", true),
            ("windows-1251", true),
            ("macintosh", true)
        ]
        for testCase in cases {
            let flagged = favorite(encodedAs: testCase.encodingName).encodingCannotRepresentEveryCharacter
            #expect(flagged == testCase.isFlagged, "\(testCase.encodingName)")
        }
    }

    @Test("The encoding is named the way macOS names it, and an unknown name is shown as stored")
    func namesTheEncoding() {
        #expect(favorite(encodedAs: "cp932").encodingDisplayName == String.localizedName(of: .shiftJIS))
        #expect(favorite(encodedAs: "no-such-charset").encodingDisplayName == "no-such-charset")
        #expect(favorite(encodedAs: "no-such-charset").encodingCannotRepresentEveryCharacter)
    }
}
