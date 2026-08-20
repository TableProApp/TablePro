//
//  SelectionAwareTintTests.swift
//  TableProTests
//

import SwiftUI
import Testing

@testable import TablePro

@Suite("Selection Aware Tint")
struct SelectionAwareTintTests {
    @Test("A prominent selection background takes the selected-content colour")
    func prominentBackgroundUsesSelectedContentColor() {
        let resolved = SelectionAwareTintResolver.color(standard: .accentColor, prominence: .increased)

        #expect(resolved == .emphasizedSelectionLabel)
    }

    @Test("A standard background keeps the tint")
    func standardBackgroundKeepsTint() {
        let resolved = SelectionAwareTintResolver.color(standard: .accentColor, prominence: .standard)

        #expect(resolved == .accentColor)
    }

    @Test("A secondary tint follows the same rule, so it never sits grey on the fill")
    func secondaryTintAlsoFlips() {
        #expect(SelectionAwareTintResolver.color(standard: .secondary, prominence: .increased) == .emphasizedSelectionLabel)
        #expect(SelectionAwareTintResolver.color(standard: .secondary, prominence: .standard) == .secondary)
    }
}
