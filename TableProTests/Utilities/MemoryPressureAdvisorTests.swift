//
//  MemoryPressureAdvisorTests.swift
//  TableProTests
//

import TableProPluginKit
import Testing
@testable import TablePro

@Suite("MemoryPressureAdvisor")
@MainActor
struct MemoryPressureAdvisorTests {
    @Test("budget returns positive value")
    func budgetPositive() {
        let budget = MemoryPressureAdvisor.budgetForInactiveTabs()
        #expect(budget >= 2)
        #expect(budget <= 8)
    }

    @Test("memory estimation for typical tab")
    func typicalTabEstimate() {
        let bytes = MemoryPressureAdvisor.estimatedFootprint(rowCount: 1000, columnCount: 10)
        #expect(bytes == 640_000)
    }

    @Test("memory estimation for empty tab")
    func emptyTabEstimate() {
        let bytes = MemoryPressureAdvisor.estimatedFootprint(rowCount: 0, columnCount: 10)
        #expect(bytes == 0)
    }

    @Test("memory estimation for large tab")
    func largeTabEstimate() {
        let bytes = MemoryPressureAdvisor.estimatedFootprint(rowCount: 50_000, columnCount: 20)
        #expect(bytes == 64_000_000)
    }
}
