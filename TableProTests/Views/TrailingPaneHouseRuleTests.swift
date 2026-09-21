//
//  TrailingPaneHouseRuleTests.swift
//  TableProTests
//
//  The trailing pane's surfaces carry no decorative dot and no middle-dot separator. Both read as
//  generated rather than designed, and the pane had three: an unsaved-edit marker drawn as a
//  coloured circle, the chat's typing indicator drawn as three of them, and a middle dot between the
//  counts in the CSV inspector's status bar. Status is an SF Symbol or words; separation is space.
//

import Foundation
import Testing

@Suite("Trailing pane house rules")
struct TrailingPaneHouseRuleTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    private static let scannedTrees = [
        "TablePro/Views/RowInspector",
        "TablePro/Views/Inspector",
        "TablePro/Views/AIChat",
        /// Agent mode's result column is the third trailing surface, and its rail and conversation
        /// answer to the same rule: the session on screen is marked with a glyph, not with a dot.
        "TablePro/Views/Agent",
    ]

    /// `Circle()` is the dot itself. The middle dot is banned both as the character and as its
    /// escape, since either spelling draws the same separator.
    private static let bannedSpellings = ["Circle()", "\u{00B7}", "\\u{00B7}", "\\u{00b7}"]

    /// Comments are dropped before the scan, because a comment may name what was removed.
    private static func code(of source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("No decorative dot and no middle-dot separator in the trailing pane's surfaces")
    func surfacesCarryNoDots() throws {
        var scanned = 0
        var offenders: [String] = []
        for tree in Self.scannedTrees {
            let root = Self.repositoryRoot.appendingPathComponent(tree)
            let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                scanned += 1
                let source = Self.code(of: try String(contentsOf: url, encoding: .utf8))
                for spelling in Self.bannedSpellings where source.contains(spelling) {
                    offenders.append("\(tree)/\(url.lastPathComponent): \(spelling)")
                }
            }
        }

        /// Guards the scan itself: a path that stopped resolving reads as a clean run.
        #expect(scanned > 30, "Expected to scan the pane's source trees, scanned \(scanned) files")
        #expect(offenders.isEmpty, "Use an SF Symbol or spacing instead: \(offenders.sorted())")
    }

    /// A scan that stops matching anything passes forever. This pins both halves.
    @Test("The scan catches a real dot and ignores one named in a comment")
    func scanCatchesCodeButNotComments() {
        let drawn = Self.code(of: "            Circle().fill(Color.accentColor)")
        #expect(Self.bannedSpellings.contains { drawn.contains($0) })

        let separator = Self.code(of: "        Text(verbatim: \"\u{00B7}\")")
        #expect(Self.bannedSpellings.contains { separator.contains($0) })

        let documented = Self.code(of: "    /// Drawn as an SF Symbol, not a Circle() dot.")
        #expect(Self.bannedSpellings.contains { documented.contains($0) } == false)
    }
}
