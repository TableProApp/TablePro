//
//  PaneBackgroundGuardTests.swift
//  TableProTests
//
//  A List, Form or ScrollView draws its own background, and that background follows the system.
//  Hiding it to paint another one, or wrapping a pane in the old `themedContent` surface, is how
//  panes stopped matching an unthemed Mac app.
//

import Foundation
import Testing

struct PaneBackgroundGuardTests {
    static func rules() throws -> [ThemeSourceScan.Rule] {
        [
            try ThemeSourceScan.Rule("hidden scroll content background", #"\.scrollContentBackground\(\s*\.hidden\s*\)"#),
            try ThemeSourceScan.Rule("themed content surface", #"\b[Tt]hemedContent"#),
        ]
    }

    @Test("No pane hides its control's own background")
    func panesKeepTheirOwnBackground() throws {
        let rules = try Self.rules()
        let tree = try ThemeSourceScan.scan(["TablePro"], rules: rules)
        let offenders = ThemeSourceScan.violations(in: tree.lines, rules: rules)

        #expect(tree.fileCount > 1_000, "Scanned only \(tree.fileCount) files; the tree did not resolve")
        #expect(
            offenders.isEmpty,
            """
            Let the List, Form or ScrollView draw its own background:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("The guard flags a hidden background and the themed surface")
    func matcherCatchesAViolation() throws {
        let sample = """
        Form { content }
            .scrollContentBackground(.hidden)
        List { rows }.themedContent()
        // .scrollContentBackground(.hidden) was removed
        ScrollView { rows }
            .scrollContentBackground(.visible)
        struct ThemedContentSurface: ViewModifier {}
        """
        let lines = ThemeSourceScan.flaggedLines(in: sample, rules: try Self.rules())

        #expect(lines == [2, 3, 7])
    }
}
