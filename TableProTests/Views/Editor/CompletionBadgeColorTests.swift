//
//  CompletionBadgeColorTests.swift
//  TableProTests
//
//  The completion panel is system chrome. Its kind badges drew in the editor's syntax colors for a
//  while, which put table, view and schema in one color and left white glyphs on pale fills in
//  Default Dark.
//

import AppKit
@testable import TablePro
import Testing

struct CompletionBadgeColorTests {
    @Test("Every completion kind has a system color of its own")
    func eachKindHasItsOwnSystemColor() {
        let colors = SQLCompletionKind.allCases.map(\.iconColor)

        #expect(colors.allSatisfy { $0.type == .catalog })
        #expect(Set(colors).count == SQLCompletionKind.allCases.count)
    }
}
