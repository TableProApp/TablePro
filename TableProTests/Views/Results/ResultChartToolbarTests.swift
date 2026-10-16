//
//  ResultChartToolbarTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProTheme
import Testing

@MainActor
struct ResultChartToolbarTests {
    @Test("Controls stack when the result pane is narrow")
    func controlsStackAtNarrowWidth() throws {
        let wideHeight = try renderedHeight(width: 1_000)
        let narrowHeight = try renderedHeight(width: 400)

        #expect(wideHeight > 0)
        #expect(narrowHeight > wideHeight + 40)
        #expect(narrowHeight < 220)
    }

    /// The counts are grouped for readability, and the separator is the reader's, so the expectation
    /// is built the same way rather than hard-coding a comma that only holds in some regions.
    @Test("A cap is reported as what is shown, not as a failure")
    func capsReadAsPartialResults() {
        func grouped(_ value: Int) -> String { value.formatted(.number.grouping(.automatic)) }

        #expect(
            ResultChartToolbar.noticeText(for: .points(limit: 2_000), loadedRowCount: 8_431)
                == "Showing the first \(grouped(2_000)) points of \(grouped(8_431)) loaded rows"
        )
        #expect(
            ResultChartToolbar.noticeText(for: .series(limit: 20), loadedRowCount: 100)
                == "Showing the first \(grouped(20)) series"
        )
        #expect(
            ResultChartToolbar.noticeText(for: .inspectedRows(limit: 50_000), loadedRowCount: 90_000)
                == "Charting the first \(grouped(50_000)) of \(grouped(90_000)) loaded rows"
        )
    }

    @Test("The point cap names the cap first and the loaded total second")
    func pointCapArgumentOrder() throws {
        let notice = ResultChartToolbar.noticeText(for: .points(limit: 2_000), loadedRowCount: 8_431)
        let cap = try #require(notice.range(of: 2_000.formatted(.number.grouping(.automatic))))
        let total = try #require(notice.range(of: 8_431.formatted(.number.grouping(.automatic))))

        #expect(cap.lowerBound < total.lowerBound)
    }

    /// The bar's material reads as a system band over a themed pane; its siblings draw no fill.
    @Test("The toolbar keeps its bar material until the window backdrop is themed, then draws nothing")
    func barMaterialFollowsTheBackdrop() throws {
        let corner = CGPoint(x: 0.002, y: 0.05)
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let native = try ThemeTestFixture.color(of: toolbar(width: 600), at: corner, colorScheme: .dark)
            #expect(native.alphaComponent > 0.5, "the bar drew no material: \(native)")
        }
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            let themed = try ThemeTestFixture.color(of: toolbar(width: 600), at: corner, colorScheme: .dark)
            #expect(themed.alphaComponent < 0.02, "the bar still drew a band: \(themed)")
        }
    }

    private func columns() -> [ResultChartColumn] {
        [
            ResultChartColumn(
                id: ResultChartColumnID(name: "category", occurrence: 1),
                index: 0,
                displayName: "A long category column name",
                type: .text(rawType: nil),
                isPrimaryKey: false
            ),
            ResultChartColumn(
                id: ResultChartColumnID(name: "amount", occurrence: 1),
                index: 1,
                displayName: "A long numeric column name",
                type: .decimal(rawType: nil),
                isPrimaryKey: false
            ),
            ResultChartColumn(
                id: ResultChartColumnID(name: "series", occurrence: 1),
                index: 2,
                displayName: "A long series column name",
                type: .text(rawType: nil),
                isPrimaryKey: false
            ),
        ]
    }

    private func toolbar(width: CGFloat) -> some View {
        let all = columns()
        let configuration = ResultChartConfiguration(
            chartType: .bar,
            xColumn: all[0].id,
            yColumn: all[1].id,
            seriesColumn: all[2].id
        )
        return ResultChartToolbar(
            configuration: .constant(configuration),
            columns: all,
            resolved: configuration.resolved(in: all),
            projection: ResultChartProjection(
                points: [],
                xAxisKind: .category,
                limits: [],
                loadedRowCount: 40,
                skippedRowCount: 0,
                xAxisLabel: "category",
                yAxisLabel: "amount",
                seriesLabel: nil
            )
        )
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func renderedHeight(width: CGFloat) throws -> Int {
        let all = columns()
        let configuration = ResultChartConfiguration(
            chartType: .bar,
            xColumn: all[0].id,
            yColumn: all[1].id,
            seriesColumn: all[2].id
        )
        let toolbar = ResultChartToolbar(
            configuration: .constant(configuration),
            columns: all,
            resolved: configuration.resolved(in: all),
            projection: ResultChartProjection(
                points: [],
                xAxisKind: .category,
                limits: [.points(limit: 2_000)],
                loadedRowCount: 40,
                skippedRowCount: 2,
                xAxisLabel: "A long category column name",
                yAxisLabel: "A long numeric column name",
                seriesLabel: "A long series column name"
            )
        )
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        let renderer = ImageRenderer(content: toolbar)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)

        return try #require(renderer.cgImage).height
    }
}
