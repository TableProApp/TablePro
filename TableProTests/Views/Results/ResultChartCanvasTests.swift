//
//  ResultChartCanvasTests.swift
//  TableProTests
//

import SwiftUI
@testable import TablePro
import Testing

@MainActor
@Suite("ResultChartCanvas")
struct ResultChartCanvasTests {
    @Test("Every chart type renders in both appearances", arguments: ResultChartType.allCases, [ColorScheme.light, .dark])
    func renders(type: ResultChartType, colorScheme: ColorScheme) {
        let view = ResultChartCanvas(projection: projection, chartType: type)
            .frame(width: 640, height: 360)
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1

        guard let image = renderer.cgImage else {
            Issue.record("The \(type.rawValue) chart did not render in \(colorScheme)")
            return
        }
        #expect(image.width == 640)
        #expect(image.height == 360)
    }

    private var projection: ResultChartProjection {
        ResultChartProjection(
            points: [
                point(index: 0, x: "A", y: 10, series: "First"),
                point(index: 1, x: "B", y: 20, series: "First"),
                point(index: 2, x: "A", y: 15, series: "Second"),
                point(index: 3, x: "B", y: 25, series: "Second"),
            ],
            issue: nil,
            loadedRowCount: 4,
            skippedRowCount: 0,
            xAxisLabel: "Category",
            yAxisLabel: "Amount",
            seriesLabel: "Group"
        )
    }

    private func point(index: Int, x: String, y: Int, series: String) -> ResultChartProjection.Point {
        ResultChartProjection.Point(
            sourceIndex: index,
            x: .category(x),
            y: Decimal(y),
            rawX: x,
            rawY: String(y),
            series: .value(series),
            barGroup: index,
            lineGroup: series == "First" ? 0 : 1
        )
    }
}
