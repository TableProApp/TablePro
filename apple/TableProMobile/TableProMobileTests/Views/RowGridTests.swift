import CoreGraphics
import SwiftUI
@testable import TableProMobile
import Testing
import UIKit

struct RowGridLayoutTests {
    private static let metrics = RowGridMetrics(minimumWidth: 72, maximumWidth: 320, horizontalPadding: 12)

    private static func layout(
        _ names: [String],
        _ rows: [[String?]],
        keyColumn: Int? = 0,
        measure: (String, Bool) -> CGFloat = { text, _ in CGFloat(text.count) * 8 }
    ) -> RowGridLayout {
        RowGridLayout.make(columnNames: names, rows: rows, keyColumn: keyColumn, metrics: metrics, measure: measure)
    }

    @Test("The key column leads and the rest keep table order")
    func keyColumnLeads() {
        #expect(RowGridLayout.displayOrder(columnCount: 4, keyColumn: 2) == [2, 0, 1, 3])
        #expect(RowGridLayout.displayOrder(columnCount: 4, keyColumn: 0) == [0, 1, 2, 3])
    }

    @Test("A missing or out of range key column keeps table order")
    func noKeyKeepsOrder() {
        #expect(RowGridLayout.displayOrder(columnCount: 3, keyColumn: nil) == [0, 1, 2])
        #expect(RowGridLayout.displayOrder(columnCount: 3, keyColumn: 5) == [0, 1, 2])
        #expect(RowGridLayout.displayOrder(columnCount: 0, keyColumn: 0).isEmpty)
    }

    @Test("Widths follow the display order, one per column, and a short row counts as NULL")
    func widthPerDisplayedColumn() {
        let layout = Self.layout(["a", "bbbbbbbbbbbbbbbbbbbb"], [["1"]], keyColumn: 1)
        #expect(layout.order == [1, 0])
        #expect(layout.widths == [20 * 8 + 24, 72])
        #expect(layout.totalWidth == CGFloat(20 * 8 + 24 + 72))
    }

    @Test("Widths stay between the minimum and the maximum")
    func widthsAreClamped() {
        let layout = Self.layout(["id", "body"], [["1", String(repeating: "x", count: 500)]])
        #expect(layout.widths == [72, 320])
    }

    @Test("The header is measured as a header and values as cells")
    func headerMeasuredAsHeader() {
        var measured: [String: Bool] = [:]
        _ = Self.layout(["name"], [["value"]]) { text, isHeader in
            measured[text] = isHeader
            return 0
        }
        #expect(measured == ["name": true, "value": false])
    }

    @Test("A wider measurement widens the column even with fewer characters")
    func widthFollowsMeasurement() {
        let layout = Self.layout(["c"], [["abcdefghij"], ["日本語"]]) { text, _ in
            text == "日本語" ? 200 : CGFloat(text.count) * 8
        }
        #expect(layout.widths == [200 + 24])
    }

    @Test("Only the first rows are sampled")
    func onlyFirstRowsSampled() {
        var rows: [[String?]] = Array(repeating: ["x"], count: RowGridLayout.sampledRowCount)
        rows.append([String(repeating: "y", count: 30)])
        #expect(Self.layout(["c"], rows).widths == [72])
    }

    @Test("A column already at the maximum stops measuring")
    func stopsAtMaximum() {
        var calls = 0
        let rows: [[String?]] = Array(repeating: [String(repeating: "z", count: 100)], count: 10)
        _ = Self.layout(["c"], rows) { text, _ in
            calls += 1
            return CGFloat(text.count) * 8
        }
        #expect(calls == 2)
    }

    @Test("The key column takes at most its share of the viewport, and only the key column shrinks")
    func keyColumnLimitedByViewport() {
        let layout = RowGridLayout(order: [0, 1], widths: [300, 200])
        #expect(layout.limitingKeyColumn(toViewportWidth: 400).widths == [160, 200])
        #expect(layout.limitingKeyColumn(toViewportWidth: 1_000).widths == [300, 200])
        #expect(layout.limitingKeyColumn(toViewportWidth: 0).widths == [300, 200])
        #expect(RowGridLayout(order: [], widths: []).limitingKeyColumn(toViewportWidth: 400).widths.isEmpty)
    }

    @Test("Only the first line counts, with room for the ellipsis that marks the rest")
    func firstLineWithEllipsis() {
        #expect(RowGridLayout.measuredText("first line\nsecond") == "first line…")
        #expect(RowGridLayout.measuredText("one line") == "one line")
        #expect(RowGridLayout.measuredText("") == "")
    }

    @Test("A long value is measured up to the cap, not to its end")
    func longValueCapped() {
        let text = String(repeating: "a", count: 4_096)
        let measured = RowGridLayout.measuredText(text)
        #expect(measured.count == RowGridLayout.maximumMeasuredCharacters + 1)
        #expect(measured.hasSuffix("…"))
    }
}

@MainActor
struct RowGridTextMeasureTests {
    private static let samples: [(text: String, isHeader: Bool)] = [
        ("11170334", false),
        ("2026-11-01 09:41:00", false),
        ("WWWWWWWWWW", false),
        ("For Those About To Rock (We Salute You)", false),
        ("日本語のテキストと中文", false),
        ("Ünïcødé ẞtraße", false),
        ("NULL", false),
        ("TrackId", true),
        ("PlaylistId", true),
        ("InvoiceLineId", true),
        ("AlbumId", true),
        ("UnitPrice", true),
        ("MediaTypeId", true),
    ]

    private static func renderedWidth(_ text: String, isHeader: Bool, size: DynamicTypeSize) -> CGFloat {
        let view = Text(verbatim: text)
            .font(.subheadline)
            .fontWeight(isHeader ? .semibold : nil)
            .lineLimit(1)
            .fixedSize()
            .environment(\.dynamicTypeSize, size)
        return UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
            .width
    }

    @Test("A measured width holds the text as SwiftUI renders it", arguments: [DynamicTypeSize.large, .xxxLarge, .accessibility3])
    func measuredWidthHoldsRenderedText(size: DynamicTypeSize) {
        let measure = RowGridTextMeasure(dynamicTypeSize: size)
        for sample in Self.samples {
            let measured = measure.width(of: sample.text, isHeader: sample.isHeader).rounded(.up)
            let rendered = Self.renderedWidth(sample.text, isHeader: sample.isHeader, size: size)
            #expect(measured >= rendered, "\(sample.text) at \(size): measured \(measured), rendered \(rendered)")
        }
    }

    @Test("Larger text measures wider")
    func scalesWithDynamicType() {
        let regular = RowGridTextMeasure(dynamicTypeSize: .large).width(of: "AlbumId", isHeader: false)
        let large = RowGridTextMeasure(dynamicTypeSize: .accessibility3).width(of: "AlbumId", isHeader: false)
        #expect(large > regular)
    }
}
