//
//  ResultChartSeriesStyleTests.swift
//  TableProTests
//

import SwiftUI
@testable import TablePro
import Testing

struct ResultChartSeriesStyleTests {
    @Test("A series keeps its colour whatever order the rows name it in")
    func colourIgnoresRowOrder() {
        let names = ["Widgets", "Bolts", "Nuts"]
        let forward = ResultChartSeriesStyle(series: names.map { .init(.value($0)) })
        let reversed = ResultChartSeriesStyle(series: names.reversed().map { .init(.value($0)) })

        #expect(forward.names == names)
        #expect(colours(of: forward) == colours(of: reversed))
        #expect(Set(colours(of: forward).values).count == names.count)
    }

    @Test("The legend lists series in the order the rows name them")
    func legendFollowsRowOrder() {
        let style = ResultChartSeriesStyle(series: ["Widgets", "Bolts"].map { .init(.value($0)) })

        #expect(style.entries.map(\.name) == ["Widgets", "Bolts"])
    }

    private func colours(of style: ResultChartSeriesStyle) -> [String: Color] {
        Dictionary(uniqueKeysWithValues: style.entries.map { ($0.name, $0.color) })
    }
}
