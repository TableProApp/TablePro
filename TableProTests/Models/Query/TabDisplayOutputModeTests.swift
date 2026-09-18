//
//  TabDisplayOutputModeTests.swift
//  TableProTests
//
//  Output mode shows what the active result printed. A result's rows, and the modes they allow, are installed
//  before the result replaces the old one, so the mode has to be settled when the result itself arrives.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("Tab display - Output mode")
struct TabDisplayOutputModeTests {
    private static func result(printing lines: [String]) -> ResultSet {
        let result = ResultSet(label: "Result")
        result.serverOutput = PluginServerOutput(lines: lines, isTruncated: false)
        return result
    }

    @Test("A new result that printed nothing takes the tab out of Output mode")
    func leavesOutputModeForAResultWithoutOutput() {
        var display = TabDisplayState()
        display.replaceUnpinnedResults(with: [Self.result(printing: ["first"])])
        display.resultsViewMode = .output

        display.replaceUnpinnedResults(with: [Self.result(printing: [])])

        #expect(display.resultsViewMode == .data)
    }

    @Test("A new result that printed keeps the tab in Output mode")
    func keepsOutputModeForAResultWithOutput() {
        var display = TabDisplayState()
        display.replaceUnpinnedResults(with: [Self.result(printing: ["first"])])
        display.resultsViewMode = .output

        display.replaceUnpinnedResults(with: [Self.result(printing: ["second"])])

        #expect(display.resultsViewMode == .output)
    }

    @Test("Other modes are left alone")
    func otherModesAreUntouched() {
        var display = TabDisplayState()
        display.resultsViewMode = .chart

        display.replaceUnpinnedResults(with: [Self.result(printing: [])])

        #expect(display.resultsViewMode == .chart)
    }
}
