import Foundation
import SwiftUI
import TableProModels
@testable import TableProMobile
import Testing

struct RowLayoutTests {
    @Test("With no choice made, a compact width keeps the cards and a regular width opens the grid")
    func defaultFollowsWidth() {
        #expect(RowLayout.resolved(preferred: nil, widthClass: .compact) == .cards)
        #expect(RowLayout.resolved(preferred: nil, widthClass: .regular) == .grid)
    }

    @Test("A choice the user made wins at every width", arguments: RowLayout.allCases)
    func choiceWinsAtEveryWidth(layout: RowLayout) {
        for widthClass in [DuoWidthClass.compact, .regular] {
            #expect(RowLayout.resolved(preferred: layout, widthClass: widthClass) == layout)
        }
    }

    @Test("A stored choice is read back by a later browser")
    func storedChoiceIsRemembered() throws {
        let suite = "RowLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let writer = AppStorage<RowLayout?>(RowLayout.storageKey, store: defaults)
        #expect(writer.wrappedValue == nil)
        writer.wrappedValue = .grid

        let reader = AppStorage<RowLayout?>(RowLayout.storageKey, store: defaults)
        #expect(reader.wrappedValue == .grid)
        #expect(defaults.string(forKey: RowLayout.storageKey) == "grid")
    }

    @Test("An unknown stored value falls back to the width default")
    func unknownStoredValueIsIgnored() throws {
        let suite = "RowLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("table", forKey: RowLayout.storageKey)

        let stored = AppStorage<RowLayout?>(RowLayout.storageKey, store: defaults).wrappedValue
        #expect(stored == nil)
        #expect(RowLayout.resolved(preferred: stored, widthClass: .compact) == .cards)
    }
}

struct RowGridMetricsTests {
    private static func column(_ name: String) -> ColumnInfo {
        ColumnInfo(name: name, typeName: "text")
    }

    @Test("Every column gets a width, even when a row is shorter than the header")
    func widthPerColumn() {
        let columns = [Self.column("id"), Self.column("name"), Self.column("email")]
        let widths = RowGridMetrics.columnWidths(columns: columns, rows: [["1"]], characterWidth: 8)
        #expect(widths.count == 3)
    }

    @Test("Widths stay between the minimum and the maximum")
    func widthsAreClamped() {
        let columns = [Self.column("id"), Self.column("body")]
        let rows: [[String?]] = [["1", String(repeating: "x", count: 500)]]
        let widths = RowGridMetrics.columnWidths(columns: columns, rows: rows, characterWidth: 8)
        #expect(widths[0] == RowGridMetrics.minimumColumnWidth)
        #expect(widths[1] == RowGridMetrics.maximumColumnWidth)
    }

    @Test("A longer value widens its column, and NULL counts as its label")
    func widthFollowsContent() {
        let columns = [Self.column("a"), Self.column("b")]
        let rows: [[String?]] = [["short value", nil], ["a much longer value here", nil]]
        let widths = RowGridMetrics.columnWidths(columns: columns, rows: rows, characterWidth: 8)
        #expect(widths[0] == CGFloat(24) * 8 + RowGridMetrics.cellHorizontalPadding * 2)
        #expect(widths[1] == RowGridMetrics.minimumColumnWidth)
    }

    @Test("Only the first line of a value counts toward the width")
    func multilineValueUsesFirstLine() {
        let columns = [Self.column("note")]
        let rows: [[String?]] = [["first line\n" + String(repeating: "y", count: 60)]]
        let widths = RowGridMetrics.columnWidths(columns: columns, rows: rows, characterWidth: 8)
        #expect(widths[0] == CGFloat(10) * 8 + RowGridMetrics.cellHorizontalPadding * 2)
    }
}
