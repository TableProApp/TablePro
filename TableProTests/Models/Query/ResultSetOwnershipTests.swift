//
//  ResultSetOwnershipTests.swift
//  TableProTests
//
//  A `ResultSet` is replaced on every load, page turn, sort and re-execute, so view state kept on
//  one dies at the first page turn. `QueryTab` owns that state. The boundary is easy to cross by
//  accident because it is invisible in a diff: the chart configuration was nearly put on
//  `ResultSet`, and the unread copies of the tab's own state it would have sat next to are what
//  made that look right (#2243).
//

import Foundation
@testable import TablePro
import Testing

@Suite("ResultSet ownership")
struct ResultSetOwnershipTests {
    @Test("ResultSet declares no stored property that QueryTab already owns")
    func resultSetDoesNotMirrorTheTab() throws {
        let shared = try Self.storedProperties(of: "ResultSet", in: "TablePro/Models/Query/ResultSet.swift")
            .intersection(Self.storedProperties(of: "QueryTab", in: "TablePro/Models/Query/QueryTab.swift"))

        #expect(
            shared == ["id"],
            """
            A ResultSet is rebuilt on every load, page turn, sort and re-execute, so a copy of \
            tab state kept here is read by nothing and discarded at the first page turn. Keep it \
            on QueryTab: \(shared.subtracting(["id"]).sorted())
            """
        )
    }

    /// Stored properties are the `var`/`let` declarations at type scope, which the four-space house
    /// indent pins exactly. A brace with no `=` ahead of it opens an accessor block, so the
    /// declaration computes rather than stores; a brace after one is a default value or an
    /// observer on something that does store.
    ///
    /// This compares names, so it catches a copy that keeps the name it had on `QueryTab` and
    /// nothing else. State moved back under a new name still needs a reader to notice it.
    private static func storedProperties(of type: String, in path: String) throws -> Set<String> {
        let source = try String(contentsOf: repoRoot().appendingPathComponent(path), encoding: .utf8)
        let lines = source.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0.contains("class \(type):") || $0.contains("struct \(type):")
                || $0.contains("class \(type) {") || $0.contains("struct \(type) {")
        }) else { throw CocoaError(.fileNoSuchFile) }

        var names: Set<String> = []
        for line in lines[(start + 1)...] {
            if line == "}" { break }
            guard line.hasPrefix("    "), !line.hasPrefix("     "), Self.stores(line) else { continue }
            let words = line.split(separator: " ").map(String.init)
            guard let keyword = words.firstIndex(where: { $0 == "var" || $0 == "let" }),
                  keyword + 1 < words.count
            else { continue }
            let name = words[keyword + 1].prefix { $0 != ":" && $0 != "=" }
            if !name.isEmpty { names.insert(String(name)) }
        }
        return names
    }

    private static func stores(_ line: String) -> Bool {
        guard let brace = line.firstIndex(of: "{") else { return true }
        return line[..<brace].contains("=")
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
