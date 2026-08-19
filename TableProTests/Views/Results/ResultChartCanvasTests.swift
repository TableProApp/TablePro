//
//  ResultChartCanvasTests.swift
//  TableProTests
//

import AppKit
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
            .accentColor(.red)

        guard let image = render(view, colorScheme: colorScheme) else {
            Issue.record("The \(type.rawValue) chart did not render in \(colorScheme)")
            return
        }
        #expect(image.width == 640)
        #expect(image.height == 360)
        #expect(chromaticPixelCount(in: image) > 20)
    }

    @Test(
        "A single point remains visible in line and area charts",
        arguments: [ResultChartType.line, .area], [ColorScheme.light, .dark]
    )
    func singlePointRemainsVisible(type: ResultChartType, colorScheme: ColorScheme) throws {
        let point = ResultChartProjection.Point(
            sourceIndex: 0,
            x: .category("Only"),
            y: 42,
            rawX: "Only",
            rawY: "42",
            series: nil,
            barGroup: 0,
            lineGroup: 0
        )
        let projection = ResultChartProjection(
            points: [point],
            issue: nil,
            loadedRowCount: 1,
            skippedRowCount: 0,
            xAxisLabel: "Category",
            yAxisLabel: "Amount",
            seriesLabel: nil
        )
        let view = ResultChartCanvas(projection: projection, chartType: type)
            .frame(width: 640, height: 360)
            .environment(\.colorScheme, colorScheme)
            .accentColor(.red)

        let image = try #require(render(view, colorScheme: colorScheme))

        #expect(chromaticPixelCount(in: image) > 12)
    }

    @Test(
        "Numeric X renders every chart type in both appearances",
        arguments: ResultChartType.allCases,
        [ColorScheme.light, .dark]
    )
    func numericXRendersEveryChartType(type: ResultChartType, colorScheme: ColorScheme) throws {
        let projection = ResultChartProjection(
            points: [
                numericPoint(index: 0, x: 1, y: 10),
                numericPoint(index: 1, x: 2, y: 18),
                numericPoint(index: 2, x: 3, y: 14),
            ],
            issue: nil,
            loadedRowCount: 3,
            skippedRowCount: 0,
            xAxisLabel: "Distance",
            yAxisLabel: "Amount",
            seriesLabel: nil
        )
        let view = ResultChartCanvas(projection: projection, chartType: type)
            .frame(width: 640, height: 360)
            .environment(\.colorScheme, colorScheme)
            .accentColor(.red)

        let image = try #require(render(view, colorScheme: colorScheme))

        #expect(image.width == 640)
        #expect(image.height == 360)
        #expect(chromaticPixelCount(in: image) > 20)
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

    private func numericPoint(index: Int, x: Int, y: Int) -> ResultChartProjection.Point {
        ResultChartProjection.Point(
            sourceIndex: index,
            x: .number(Decimal(x)),
            y: Decimal(y),
            rawX: String(x),
            rawY: String(y),
            series: nil,
            barGroup: 0,
            lineGroup: 0
        )
    }

    private func render<Content: View>(_ content: Content, colorScheme: ColorScheme) -> CGImage? {
        let appearanceName: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        guard let appearance = NSAppearance(named: appearanceName) else { return nil }
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            image = renderer.cgImage
        }
        return image
    }

    private func chromaticPixelCount(in image: CGImage) -> Int {
        matchingPixelCount(in: image) { color in
            color.saturationComponent > 0.35 && color.brightnessComponent > 0.25 && color.alphaComponent > 0.5
        }
    }

    private func matchingPixelCount(in image: CGImage, matches: (NSColor) -> Bool) -> Int {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if matches(color) { count += 1 }
            }
        }
        return count
    }
}
