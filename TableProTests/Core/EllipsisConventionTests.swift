//
//  EllipsisConventionTests.swift
//  TableProTests
//
//  macOS spells an ellipsis with U+2026, and AppKit's own strings do it without exception: its
//  English tables carry 69 strings containing "…" and none containing three periods. TablePro used
//  both, split by subsystem, so the same command read "New Table..." in the menu bar and "New
//  Table…" in the sidebar's context menu.
//

import Foundation
import Testing

@Suite("Ellipsis convention")
struct EllipsisConventionTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    /// Three periods are correct in these: they are SQL notation rather than a UI ellipsis, in the
    /// form SQL documentation itself uses. Anything else with three periods is a UI string that
    /// should carry U+2026.
    private static let technicalNotation = ["ALTER...DROP", "OVER(...)", ", ...)"]

    private func isTechnical(_ key: String) -> Bool {
        Self.technicalNotation.contains { key.contains($0) }
    }

    @Test("No live string in the catalog spells an ellipsis with three periods")
    func catalogUsesTheUnicodeEllipsis() throws {
        let url = Self.repositoryRoot
            .appendingPathComponent("TablePro/Resources/Localizable.xcstrings")
        let raw = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        let strings = try #require(parsed?["strings"] as? [String: [String: Any]])

        let offenders = strings.filter { key, entry in
            guard key.contains("...") else { return false }
            /// A stale key is not shipping: it stayed behind when its UI was removed or renamed, so
            /// it is a separate cleanup rather than a spelling the user can see.
            guard (entry["extractionState"] as? String) != "stale" else { return false }
            return !isTechnical(key)
        }

        #expect(
            offenders.isEmpty,
            "These strings should spell their ellipsis \"…\": \(offenders.keys.sorted())"
        )
    }
}
