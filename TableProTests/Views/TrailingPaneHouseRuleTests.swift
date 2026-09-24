//
//  TrailingPaneHouseRuleTests.swift
//  TableProTests
//
//  The connection window's panes carry no decorative dot and no middle-dot separator. Both read as
//  generated rather than designed, and there were five: an unsaved-edit marker drawn as a coloured
//  circle, the chat's typing indicator drawn as three of them, a middle dot between the counts in
//  the data file window's status bar, and in the query history drawer a connection dot and two more
//  middle dots. Status is an SF Symbol or words; separation is space.
//

import Foundation
import Testing

@Suite("Connection window pane house rules")
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
        "TablePro/Views/DataFiles",
        "TablePro/Views/AIChat",
        /// Agent mode's result column is the third trailing surface, and its rail and conversation
        /// answer to the same rule: the session on screen is marked with a glyph, not with a dot.
        "TablePro/Views/Agent",
        /// The query history drawer is the window's other pane of rows, and it had both defects at
        /// once: the connection named by a filled dot, and two middle dots holding its three facts
        /// apart.
        "TablePro/Views/Editor/History",
    ]

    /// `Circle()` is the dot itself, and a bare `"circle.fill"` is the same dot drawn as a symbol,
    /// which is what the history drawer named its connection with. Matching the literal with its
    /// opening quote is what keeps the compound symbols the panes do use out of it: every one of
    /// them, `checkmark.circle.fill` and the rest, carries a word between the quote and `circle`.
    ///
    /// The middle dot is banned both as the character and as its escape, since either spelling
    /// draws the same separator.
    private static let bannedSpellings = ["Circle()", "\"circle.fill\"", "\u{00B7}", "\\u{00B7}", "\\u{00b7}"]

    /// Comments are dropped before the scan, because a comment may name what was removed.
    private static func code(of source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("No decorative dot and no middle-dot separator in the connection window's panes")
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

        let symbol = Self.code(of: "            Image(systemName: \"circle.fill\").font(.system(size: 6))")
        #expect(Self.bannedSpellings.contains { symbol.contains($0) })

        /// The other half of that spelling: a status glyph that happens to end in `circle.fill` is
        /// the affordance the rule asks for, so banning it would ban the fix.
        let compound = Self.code(of: "            Image(systemName: \"checkmark.circle.fill\")")
        #expect(Self.bannedSpellings.contains { compound.contains($0) } == false)

        let documented = Self.code(of: "    /// Drawn as an SF Symbol, not a Circle() dot.")
        #expect(Self.bannedSpellings.contains { documented.contains($0) } == false)
    }
}
