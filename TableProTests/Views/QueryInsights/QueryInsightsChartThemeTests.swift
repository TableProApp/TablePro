//
//  QueryInsightsChartThemeTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProTheme
import Testing

/// A chart plot takes the grid's lines and background, as the result chart does, and draws the
/// default grid line and no plot fill while the theme leaves those slots out.
@MainActor
struct QueryInsightsChartThemeTests {
    private static let size = CGSize(width: 480, height: 260)

    private var chart: some View {
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let buckets = (0 ..< 6).map { day in
            QueryInsightsActivityBucket(
                date: start.addingTimeInterval(Double(day) * 86_400),
                totalCount: 4 + day,
                failedCount: day % 2
            )
        }
        return QueryInsightsActivityChart(buckets: buckets, granularity: .daily)
            .frame(width: Self.size.width, height: Self.size.height)
    }

    private func count(_ predicate: (NSColor) -> Bool) throws -> Int {
        let rep = try #require(ThemeTestFixture.render(chart, colorScheme: .dark, scale: 2))
        return ThemeTestFixture.count(in: rep, where: predicate)
    }

    @Test("The plot takes the grid background only while the theme sets it")
    func plotTakesTheGridBackground() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let grid = try ThemeTestFixture.filled(hex: ThemeTestFixture.gridHex, colorScheme: .dark)
            let isGrid: (NSColor) -> Bool = { ThemeTestFixture.matches($0, grid, tolerance: 0.01) }
            #expect(try count(isGrid) == 0)

            try ThemeTestFixture.adopt([.gridBackground: ThemeTestFixture.gridHex], appearance: .dark)
            #expect(try count(isGrid) > 10_000)
        }
    }

    @Test("The grid lines take the grid line color only while the theme sets it")
    func gridLinesTakeTheGridLineColor() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            #expect(try count(ThemeTestFixture.isMagenta) == 0)

            try ThemeTestFixture.adopt([.gridLine: "#FF00FF"], appearance: .dark)
            #expect(try count(ThemeTestFixture.isMagenta) > 100)
        }
    }
}
