//
//  KeywordVocabularyParityTests.swift
//  TableProTests
//
//  Two lists decide what counts as a SQL keyword, and nothing made them agree. The completion
//  provider offers keywords from clause-specific arrays written inline in `getCandidates`, while
//  Auto-uppercase consults `SQLKeywords.keywordSet` alone, so a word the popup had offered a
//  keystroke earlier was left in lower case: `alter table users add column note text;` came out as
//  `ALTER TABLE users add COLUMN note TEXT;`.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Keyword vocabulary parity")
struct KeywordVocabularyParityTests {
    /// The uppercaser only ever looks at one word at a time, so a multi-word entry such as
    /// `ORDER BY` can never match and is not expected in the set.
    @Test("Every single-word keyword the provider offers is one the uppercaser knows")
    func offeredKeywordsAreUppercasable() throws {
        let offered = try Self.providerOfferedKeywords()
        #expect(offered.count > 50, "The provider source parsed to a real vocabulary")

        let unknown = offered
            .filter { $0.allSatisfy(\.isLetter) || $0.contains("_") }
            .filter { !SQLKeywords.keywordSet.contains($0.lowercased()) }
            .sorted()

        #expect(
            unknown.isEmpty,
            """
            SQLCompletionProvider offers these as keyword completions, but SQLKeywords.keywordSet \
            does not contain them, so Auto-uppercase leaves them in whatever case the user typed \
            while uppercasing the words around them: \(unknown)
            """
        )
    }

    @Test("The uppercaser's set holds only single words, in lower case")
    func keywordSetShape() {
        #expect(!SQLKeywords.keywordSet.isEmpty)
        #expect(SQLKeywords.keywordSet.allSatisfy { !$0.contains(" ") })
        #expect(SQLKeywords.keywordSet.allSatisfy { $0 == $0.lowercased() })
    }

    /// The words the reported defect named, kept as an explicit list so a future edit that drops
    /// one fails here rather than quietly reopening the gap.
    @Test(
        "The keywords the gap was reported against are uppercasable",
        arguments: [
            "add", "change", "after", "comment", "collate", "charset", "engine",
            "tablespace", "merge", "upsert", "call", "use", "replace",
            "signed", "unsigned", "range", "groups", "btree", "hash", "gin", "gist"
        ]
    )
    func reportedKeywordsAreKnown(keyword: String) {
        #expect(SQLKeywords.keywordSet.contains(keyword))
    }

    /// The reported statement, walked word by word the way the uppercaser sees it. Every keyword in
    /// it is now recognised; `users` and `note` are identifiers and stay untouched.
    @Test("The reported statement uppercases every keyword and nothing else")
    func reportedStatementUppercasesConsistently() {
        let statement = "alter table users add column note text"
        let words = statement.split(separator: " ").map(String.init)
        let recognised = words.filter { SQLKeywords.keywordSet.contains($0) }
        #expect(recognised == ["alter", "table", "add", "column", "text"])

        let text = statement as NSString
        let endOfAdd = text.range(of: "add").location + 3
        #expect(KeywordUppercaseHelper.keywordBeforePosition(text, at: endOfAdd)?.word == "add")

        let endOfUsers = text.range(of: "users").location + 5
        #expect(KeywordUppercaseHelper.keywordBeforePosition(text, at: endOfUsers) == nil)
    }

    private static func providerOfferedKeywords(file: StaticString = #filePath) throws -> Set<String> {
        let source = try repositoryRoot(file: file)
            .appendingPathComponent("TablePro/Core/Autocomplete/SQLCompletionProvider.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        var found: Set<String> = []
        for marker in ["filterKeywords([", "boostedKeywords([", "statementStartKeywords = ["] {
            var searchStart = text.startIndex
            while let open = text.range(of: marker, range: searchStart..<text.endIndex) {
                guard let close = text.range(of: "]", range: open.upperBound..<text.endIndex) else { break }
                found.formUnion(Self.quotedStrings(in: text[open.upperBound..<close.lowerBound]))
                searchStart = close.upperBound
            }
        }
        guard !found.isEmpty else { throw ParityError.sourceNotFound }
        return found
    }

    private static func quotedStrings(in fragment: Substring) -> [String] {
        fragment
            .split(separator: "\n")
            .map { $0.components(separatedBy: "//").first ?? "" }
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: ["\""]) }
            .filter { !$0.isEmpty }
    }

    private static func repositoryRoot(file: StaticString) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("TablePro/Core/Autocomplete/SQLKeywords.swift")
            if FileManager.default.fileExists(atPath: candidate.path) { return directory }
            directory = directory.deletingLastPathComponent()
        }
        throw ParityError.sourceNotFound
    }

    private enum ParityError: Error {
        case sourceNotFound
    }
}
