//
//  ResultChartSeriesStyle.swift
//  TablePro
//

import Charts
import SwiftUI

/// The colour, symbol and dash each series takes. Every panel of a faceted chart and the legend
/// under them read this one table, so a series looks the same wherever it appears. A series takes
/// the style of its place in sorted order, not in row order, so re-sorting the rows or turning the
/// page does not repaint every series.
struct ResultChartSeriesStyle {
    /// Swift Charts' own categorical palette, in its order: measured identical to the default in
    /// light, dark and both high-contrast appearances.
    private static let palette: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .yellow]

    /// The symbols Swift Charts gives a `PointMark` by default, in its order, measured the same way.
    private static let symbolShapes: [BasicChartSymbolShape] = [
        .circle, .cross, .triangle, .plus, .square, .asterisk, .diamond,
    ]

    /// Solid first, then patterns that stay legible in monochrome and to a colour-blind reader,
    /// because colour alone does not distinguish a series.
    private static let dashPatterns: [[CGFloat]] = [
        [], [6, 3], [2, 3], [8, 3, 2, 3], [1, 3], [10, 4],
    ]

    struct Entry: Identifiable {
        let name: String
        let color: Color
        let symbol: BasicChartSymbolShape
        let stroke: StrokeStyle

        var id: String { name }
    }

    /// In the legend's order, which is the order the rows first name them.
    let names: [String]
    private let ranks: [Int]

    init(series: [ResultChartProjection.Group]) {
        names = series.map(\.label)
        let sorted = series.indices.sorted {
            ResultChartProjection.GroupValue.areInIncreasingOrder(series[$0].value, series[$1].value)
        }
        var ranks = Array(repeating: 0, count: series.count)
        for (rank, index) in sorted.enumerated() { ranks[index] = rank }
        self.ranks = ranks
    }

    var isEmpty: Bool { names.isEmpty }

    var colors: [Color] { ranks.map(Self.color(at:)) }

    var symbols: [BasicChartSymbolShape] { ranks.map(Self.symbol(at:)) }

    var strokes: [StrokeStyle] { ranks.map(Self.stroke(at:)) }

    var entries: [Entry] {
        zip(names, ranks).map { name, rank in
            Entry(name: name, color: Self.color(at: rank), symbol: Self.symbol(at: rank), stroke: Self.stroke(at: rank))
        }
    }

    private static func color(at rank: Int) -> Color {
        palette[rank % palette.count]
    }

    private static func symbol(at rank: Int) -> BasicChartSymbolShape {
        symbolShapes[rank % symbolShapes.count]
    }

    private static func stroke(at rank: Int) -> StrokeStyle {
        StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: dashPatterns[rank % dashPatterns.count])
    }
}
