//
//  SortableHeaderRenderingTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

@Suite("SortableHeaderView chrome rendering")
@MainActor
struct SortableHeaderRenderingTests {
    private struct Grid {
        let window: NSWindow
        let headerView: SortableHeaderView
        let headerCell: SortableHeaderCell
    }

    private func makeGrid(comment: String?) -> Grid {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let tableView = NSTableView(frame: scrollView.bounds)
        tableView.style = .plain

        let identifier = NSUserInterfaceItemIdentifier("code")
        let column = NSTableColumn(identifier: identifier)
        column.width = 360
        let headerCell = SortableHeaderCell(textCell: "code")
        headerCell.font = column.headerCell.font
        column.headerCell = headerCell
        tableView.addTableColumn(column)

        let headerView = SortableHeaderView(frame: tableView.headerView?.frame ?? .zero)
        tableView.headerView = headerView
        scrollView.documentView = tableView

        let window = makeWindow(content: scrollView)

        if let comment {
            headerView.updateComments([identifier: comment])
            headerView.showsComments = true
        }

        scrollView.tile()
        window.layoutIfNeeded()
        return Grid(window: window, headerView: headerView, headerCell: headerCell)
    }

    private func makeWindow(content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = content
        window.layoutIfNeeded()
        return window
    }

    private func brightnessColumn(of view: NSView, atX sampleX: CGFloat) -> [CGFloat] {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / view.bounds.height
        let x = min(rep.pixelsWide - 1, Int(sampleX * scale))
        return (0 ..< rep.pixelsHigh).map { rep.colorAt(x: x, y: $0)?.brightnessComponent ?? 0 }
    }

    private func ruleOffsets(in view: NSView, atX sampleX: CGFloat = 300) -> [CGFloat] {
        let brightness = brightnessColumn(of: view, atX: sampleX)
        guard !brightness.isEmpty else { return [] }
        let scale = CGFloat(brightness.count) / view.bounds.height
        let span = max(1, Int((3 * scale).rounded()))
        return brightness.indices.compactMap { index in
            guard abs(brightness[index] - brightness[max(0, index - span)]) > 0.02 else { return nil }
            return CGFloat(index) / scale
        }
    }

    private func isAlongBottomEdge(_ offset: CGFloat, of view: NSView) -> Bool {
        offset >= view.bounds.height - SortableHeaderChrome.separatorThickness
    }

    @Test("The comment header draws its only horizontal rule along the bottom edge")
    func commentHeaderRuleSitsAlongBottomEdge() {
        let grid = makeGrid(comment: "ISO 4217 exponent for the minor unit")
        let offsets = ruleOffsets(in: grid.headerView)

        #expect(!offsets.isEmpty)
        #expect(offsets.allSatisfy { isAlongBottomEdge($0, of: grid.headerView) })
    }

    @Test("The comment header draws no horizontal rule across the comment line")
    func commentHeaderDrawsNoRuleAcrossTheCommentLine() {
        let grid = makeGrid(comment: "ISO 4217 exponent for the minor unit")
        let naturalHeight = grid.headerView.commentHeaderHeight - SortableHeaderCell.commentLineHeight
        let centredBandBottom = (grid.headerView.commentHeaderHeight + naturalHeight) / 2
            - SortableHeaderChrome.separatorThickness

        let offsets = ruleOffsets(in: grid.headerView)

        #expect(!offsets.contains { abs($0 - centredBandBottom) < 1 })
    }

    @Test("The bottom rule spans past the trailing edge of the last column")
    func bottomRuleSpansPastTheLastColumn() {
        let grid = makeGrid(comment: "ISO 4217 exponent for the minor unit")
        let offsets = ruleOffsets(in: grid.headerView, atX: 390)

        #expect(!offsets.isEmpty)
        #expect(offsets.allSatisfy { isAlongBottomEdge($0, of: grid.headerView) })
    }

    @Test("The natural height header keeps its rule along the bottom edge")
    func naturalHeaderRuleSitsAlongBottomEdge() {
        let grid = makeGrid(comment: nil)
        let offsets = ruleOffsets(in: grid.headerView)

        #expect(!offsets.isEmpty)
        #expect(offsets.allSatisfy { isAlongBottomEdge($0, of: grid.headerView) })
    }

    @Test("Selecting a column highlights the full height of the comment header")
    func selectionHighlightSpansTheCommentHeader() {
        let grid = makeGrid(comment: "ISO 4217 exponent for the minor unit")
        let unselected = brightnessColumn(of: grid.headerView, atX: 300)

        grid.headerCell.isColumnSelected = true
        grid.headerView.needsDisplay = true
        let selected = brightnessColumn(of: grid.headerView, atX: 300)

        #expect(!unselected.isEmpty)
        #expect(unselected.count == selected.count)
        let repainted = zip(unselected, selected).filter { abs($0 - $1) > 0.02 }.count
        #expect(repainted >= unselected.count - 4)
    }
}
