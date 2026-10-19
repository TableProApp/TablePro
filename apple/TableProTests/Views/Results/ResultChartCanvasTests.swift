//
//  ResultChartCanvasTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProTheme
import Testing

@MainActor
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
            xAxisKind: .category,
            limits: [],
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
            xAxisKind: .number,
            limits: [],
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

    @Test(
        "A date axis renders every chart type in both appearances",
        arguments: ResultChartType.allCases,
        [ColorScheme.light, .dark]
    )
    func dateXRendersEveryChartType(type: ResultChartType, colorScheme: ColorScheme) throws {
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        let projection = ResultChartProjection(
            points: (0 ..< 4).map { index in
                ResultChartProjection.Point(
                    sourceIndex: index,
                    x: .date(start.addingTimeInterval(Double(index) * 86_400)),
                    y: Double(10 + index * 4),
                    rawX: "2024-01-0\(index + 1)",
                    rawY: String(10 + index * 4),
                    series: nil,
                    barGroup: 0,
                    lineGroup: 0
                )
            },
            xAxisKind: .date,
            limits: [],
            loadedRowCount: 4,
            skippedRowCount: 0,
            xAxisLabel: "Invoiced",
            yAxisLabel: "Total",
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

    @Test("A repeated category's second bar stays inside its own band")
    func repeatedCategoryBarsStayBanded() throws {
        let projection = ResultChartProjection(
            points: [
                bandPoint(index: 0, x: "paid", y: 100, group: 0),
                bandPoint(index: 1, x: "paid", y: 60, group: 1),
                bandPoint(index: 2, x: "pending", y: 30, group: 0),
            ],
            xAxisKind: .category,
            limits: [],
            loadedRowCount: 3,
            skippedRowCount: 0,
            xAxisLabel: "Status",
            yAxisLabel: "Amount",
            seriesLabel: nil
        )
        let view = ResultChartCanvas(projection: projection, chartType: .bar)
            .frame(width: 700, height: 360)
            .environment(\.colorScheme, ColorScheme.light)
            .accentColor(.red)
        let image = try #require(render(view, colorScheme: .light))
        let bitmap = NSBitmapImageRep(cgImage: image)

        var columns: [Int] = []
        for x in 0 ..< bitmap.pixelsWide {
            for y in 0 ..< bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.saturationComponent > 0.35, color.brightnessComponent > 0.25,
                      color.alphaComponent > 0.5
                else {
                    continue
                }
                columns.append(x)
                break
            }
        }
        let bars = contiguousRuns(in: columns)

        #expect(bars.count == 3)
        let widths = bars.map { $0.upperBound - $0.lowerBound }
        let narrowest = try #require(widths.min())
        let widest = try #require(widths.max())
        #expect(widest - narrowest <= 4)
    }

    /// The first series to appear used to take the first colour, so a panel where only the second
    /// series has rows drew it blue while the panel beside it drew it green.
    @Test("A series keeps its colour in a panel where it appears alone")
    func seriesKeepsItsColourAcrossPanels() throws {
        let projection = ResultChartProjection(
            points: [
                facetPoint(index: 0, x: "Jan", y: 10, series: "Online", facet: "East"),
                facetPoint(index: 1, x: "Jan", y: 12, series: "Retail", facet: "East"),
                facetPoint(index: 2, x: "Jan", y: 14, series: "Retail", facet: "West"),
            ],
            xAxisKind: .category,
            limits: [],
            loadedRowCount: 3,
            skippedRowCount: 0,
            xAxisLabel: "Month",
            yAxisLabel: "Revenue",
            seriesLabel: "Channel",
            facetLabel: "Region"
        )
        let west = try #require(projection.panels.first { $0.facet?.label == "West" })
        let view = ResultChartCanvas(projection: projection, panel: west, chartType: .bar, showsLegend: false)
            .frame(width: 640, height: 360)
        let image = try #require(render(view, colorScheme: .light))

        let green = matchingPixelCount(in: image) { Self.hue(of: $0, isWithin: 120...160) }
        let blue = matchingPixelCount(in: image) { Self.hue(of: $0, isWithin: 195...225) }
        #expect(green > 200)
        #expect(blue == 0)
    }

    /// Swift Charts orders bar slots by first appearance in each chart, so a panel whose rows name
    /// the later series first used to draw the two bars the other way round from its neighbour.
    @Test("A panel puts each series' bar where the other panels do")
    func barOrderMatchesAcrossPanels() throws {
        let projection = ResultChartProjection(
            points: [
                facetPoint(index: 0, x: "Jan", y: 10, series: "Online", facet: "East"),
                facetPoint(index: 1, x: "Jan", y: 12, series: "Retail", facet: "East"),
                facetPoint(index: 2, x: "Jan", y: 14, series: "Retail", facet: "West"),
                facetPoint(index: 3, x: "Jan", y: 16, series: "Online", facet: "West"),
            ],
            xAxisKind: .category,
            limits: [],
            loadedRowCount: 4,
            skippedRowCount: 0,
            xAxisLabel: "Month",
            yAxisLabel: "Revenue",
            seriesLabel: "Channel",
            facetLabel: "Region"
        )
        let west = try #require(projection.panels.first { $0.facet?.label == "West" })
        let view = ResultChartCanvas(projection: projection, panel: west, chartType: .bar, showsLegend: false)
            .frame(width: 640, height: 360)
        let image = try #require(render(view, colorScheme: .light))

        let online = try #require(firstColumn(in: image) { Self.hue(of: $0, isWithin: 195...225) })
        let retail = try #require(firstColumn(in: image) { Self.hue(of: $0, isWithin: 120...160) })
        #expect(online < retail)
    }

    @Test("A panel missing a series keeps its other bars at the width and place they have elsewhere")
    func sparsePanelBarsKeepTheirSlot() throws {
        let projection = ResultChartProjection(
            points: [
                facetPoint(index: 0, x: "Jan", y: 10, series: "Online", facet: "East"),
                facetPoint(index: 1, x: "Jan", y: 12, series: "Retail", facet: "East"),
                facetPoint(index: 2, x: "Jan", y: 14, series: "Retail", facet: "West"),
            ],
            xAxisKind: .category,
            limits: [],
            loadedRowCount: 3,
            skippedRowCount: 0,
            xAxisLabel: "Month",
            yAxisLabel: "Revenue",
            seriesLabel: "Channel",
            facetLabel: "Region"
        )
        func retailColumns(in facet: String) throws -> ClosedRange<Int> {
            let panel = try #require(projection.panels.first { $0.facet?.label == facet })
            let view = ResultChartCanvas(projection: projection, panel: panel, chartType: .bar, showsLegend: false)
                .frame(width: 640, height: 360)
            let image = try #require(render(view, colorScheme: .light))
            let first = try #require(firstColumn(in: image) { Self.hue(of: $0, isWithin: 120...160) })
            let last = try #require(lastColumn(in: image) { Self.hue(of: $0, isWithin: 120...160) })
            return first...last
        }

        let east = try retailColumns(in: "East")
        let west = try retailColumns(in: "West")
        #expect(abs(east.lowerBound - west.lowerBound) <= 1)
        #expect(abs(east.upperBound - west.upperBound) <= 1)
    }

    private func lastColumn(in image: CGImage, where matches: (NSColor) -> Bool) -> Int? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        for x in (0 ..< bitmap.pixelsWide).reversed() {
            for y in 0 ..< bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if matches(color) { return x }
            }
        }
        return nil
    }

    private func firstColumn(in image: CGImage, where matches: (NSColor) -> Bool) -> Int? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        for x in 0 ..< bitmap.pixelsWide {
            for y in 0 ..< bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if matches(color) { return x }
            }
        }
        return nil
    }

    @Test("A faceted grid draws every panel in both appearances", arguments: [ColorScheme.light, .dark])
    func facetGridRendersEveryPanel(colorScheme: ColorScheme) throws {
        let projection = ResultChartProjection(
            points: ["East", "North", "West"].enumerated().flatMap { offset, region in
                [
                    facetPoint(index: offset * 2, x: "Jan", y: 10 + offset, series: "Online", facet: region),
                    facetPoint(index: offset * 2 + 1, x: "Feb", y: 20 + offset, series: "Online", facet: region),
                ]
            },
            xAxisKind: .category,
            limits: [],
            loadedRowCount: 6,
            skippedRowCount: 0,
            xAxisLabel: "Month",
            yAxisLabel: "Revenue",
            seriesLabel: "Channel",
            facetLabel: "Region"
        )
        let layout = ResultChartFacetLayout(panelCount: projection.panels.count, size: CGSize(width: 960, height: 400))
        let view = ResultChartFacetPanels(projection: projection, chartType: .bar, layout: layout, revision: 0)
            .frame(width: 960, height: 400)
            .environment(\.colorScheme, colorScheme)
        let image = try #require(render(view, colorScheme: colorScheme))
        let bitmap = NSBitmapImageRep(cgImage: image)

        var columns: [Int] = []
        for x in 0 ..< bitmap.pixelsWide {
            for y in 0 ..< bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      Self.hue(of: color, isWithin: 195...225)
                else {
                    continue
                }
                columns.append(x)
                break
            }
        }
        #expect(projection.panels.count == 3)
        #expect(contiguousRuns(in: columns).count >= 6)
    }

    private static func hue(of color: NSColor, isWithin degrees: ClosedRange<CGFloat>) -> Bool {
        color.saturationComponent > 0.35 && color.brightnessComponent > 0.25 && color.alphaComponent > 0.5
            && degrees.contains(color.hueComponent * 360)
    }

    private func facetPoint(index: Int, x: String, y: Int, series: String, facet: String) -> ResultChartProjection.Point {
        ResultChartProjection.Point(
            sourceIndex: index,
            x: .category(x),
            y: Double(y),
            rawX: x,
            rawY: String(y),
            series: .init(.value(series)),
            facet: .init(.value(facet)),
            barGroup: series == "Online" ? 0 : 1,
            lineGroup: 0
        )
    }

    @Test("The plot stands in for the grid: its background under a theme, its own wash by default")
    func plotTakesTheGridBackground() throws {
        try ThemeTestFixture.preservingEngine {
            let view = ResultChartCanvas(projection: singleSeriesProjection, chartType: .bar)
                .frame(width: 640, height: 360)
                .accentColor(.red)
            let total = 640 * 360
            let theme = try ThemeTestFixture.filled(hex: "#FFD0E0", colorScheme: .light)
            let wash = try ThemeTestFixture.filled(
                Color(nsColor: .controlBackgroundColor).opacity(0.45), colorScheme: .light
            )

            try ThemeTestFixture.adopt([:], appearance: .light)
            let native = try #require(ThemeTestFixture.render(view, colorScheme: .light))
            #expect(ThemeTestFixture.count(in: native, where: { ThemeTestFixture.matches($0, theme) }) == 0)
            #expect(ThemeTestFixture.count(in: native, where: { ThemeTestFixture.matches($0, wash) }) > total / 5)

            try ThemeTestFixture.adopt([.gridBackground: "#FFD0E0"], appearance: .light)
            let themed = try #require(ThemeTestFixture.render(view, colorScheme: .light))
            #expect(ThemeTestFixture.count(in: themed, where: { ThemeTestFixture.matches($0, theme) }) > total / 5)
            #expect(ThemeTestFixture.count(in: themed, where: { ThemeTestFixture.matches($0, wash) }) < total / 50)
        }
    }

    @Test("The plot's grid lines take the grid line color under a theme")
    func gridLinesTakeTheGridLineColor() throws {
        try ThemeTestFixture.preservingEngine {
            let view = ResultChartCanvas(projection: singleSeriesProjection, chartType: .bar)
                .frame(width: 640, height: 360)
                .accentColor(.red)

            try ThemeTestFixture.adopt([.gridBackground: "#000000"], appearance: .light)
            let native = try #require(ThemeTestFixture.render(view, colorScheme: .light))
            try ThemeTestFixture.adopt([.gridBackground: "#000000", .gridLine: "#0000FF"], appearance: .light)
            let themed = try #require(ThemeTestFixture.render(view, colorScheme: .light))

            #expect(bluePixelCount(in: native) == 0)
            #expect(bluePixelCount(in: themed) > 200)
        }
    }

    private func bluePixelCount(in rep: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = ThemeTestFixture.pixel(rep, x: x, y: y) else { continue }
                if color.blueComponent - max(color.redComponent, color.greenComponent) > 0.3 { count += 1 }
            }
        }
        return count
    }

    private var singleSeriesProjection: ResultChartProjection {
        ResultChartProjection(
            points: [
                bandPoint(index: 0, x: "A", y: 10, group: 0),
                bandPoint(index: 1, x: "B", y: 20, group: 1),
                bandPoint(index: 2, x: "C", y: 15, group: 2),
            ],
            xAxisKind: .category,
            limits: [],
            loadedRowCount: 3,
            skippedRowCount: 0,
            xAxisLabel: "Category",
            yAxisLabel: "Amount",
            seriesLabel: nil
        )
    }

    private func bandPoint(index: Int, x: String, y: Int, group: Int) -> ResultChartProjection.Point {
        ResultChartProjection.Point(
            sourceIndex: index,
            x: .category(x),
            y: Double(y),
            rawX: x,
            rawY: String(y),
            series: nil,
            barGroup: group,
            lineGroup: 0
        )
    }

    private func contiguousRuns(in columns: [Int]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        var previous: Int?
        for column in columns {
            if let last = previous, column > last + 1, let began = start {
                runs.append(began ..< last + 1)
                start = column
            }
            if start == nil { start = column }
            previous = column
        }
        if let began = start, let last = previous { runs.append(began ..< last + 1) }
        return runs
    }

    private var projection: ResultChartProjection {
        ResultChartProjection(
            points: [
                point(index: 0, x: "A", y: 10, series: "First"),
                point(index: 1, x: "B", y: 20, series: "First"),
                point(index: 2, x: "A", y: 15, series: "Second"),
                point(index: 3, x: "B", y: 25, series: "Second"),
            ],
            xAxisKind: .category,
            limits: [],
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
            y: Double(y),
            rawX: x,
            rawY: String(y),
            series: .init(.value(series)),
            barGroup: index,
            lineGroup: series == "First" ? 0 : 1
        )
    }

    private func numericPoint(index: Int, x: Int, y: Int) -> ResultChartProjection.Point {
        ResultChartProjection.Point(
            sourceIndex: index,
            x: .number(Double(x)),
            y: Double(y),
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
