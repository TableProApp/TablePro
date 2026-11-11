//
//  EditorTabLocatedWidthTests.swift
//  TableProTests
//
//  A located title (`orders@shop_demo (Shop Demo)`) is longer than an equal share of the strip, so it
//  asks for its own width and takes it from the tabs that ask for none, down to the minimum a name
//  fits in. The reorder follows the widths the run draws.
//

import CoreGraphics
import Foundation
import Testing

@testable import TablePro

struct EditorTabLocatedWidthTests {
    private static let wideTrack: CGFloat = 1_180
    private static var usable: CGFloat { wideTrack - EditorTabStripLayout.trackPadding * 2 }

    private static func widths(_ run: EditorTabRunLayout) -> [CGFloat] {
        run.placements.sorted { $0.index < $1.index }.map(\.frame.width)
    }

    private static func isClose(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 0.001
    }

    // MARK: - Widths

    @Test("Without a preferred width the run is the equal share it always was")
    func noPreferenceKeepsTheEqualShare() {
        let plain = EditorTabRunLayoutBuilder.run(forTrack: Self.wideTrack, count: 7, overflow: .scroll)
        let unasked = EditorTabRunLayoutBuilder.run(
            forTrack: Self.wideTrack, count: 7, overflow: .scroll, preferredWidths: Array(repeating: nil, count: 7)
        )
        let modest = EditorTabRunLayoutBuilder.run(
            forTrack: Self.wideTrack, count: 7, overflow: .scroll, preferredWidths: [130, nil, 140, nil, nil, nil, nil]
        )

        #expect(unasked == plain)
        #expect(modest == plain)
    }

    @Test("A located tab grows to its whole title when the other tabs can give it room")
    func locatedTabGrowsWhenThereIsRoom() {
        let run = EditorTabRunLayoutBuilder.run(
            forTrack: Self.wideTrack, count: 7, overflow: .scroll,
            preferredWidths: [nil, 205, nil, 225, nil, nil, nil]
        )
        let widths = Self.widths(run)
        let others = (Self.usable - 430) / 5

        #expect(widths[1] == 205)
        #expect(widths[3] == 225)
        #expect([0, 2, 4, 5, 6].allSatisfy { Self.isClose(widths[$0], others) })
        #expect(Self.isClose(run.contentSize.width, Self.usable))
        #expect(run.rowCount == 1)
    }

    @Test("The tabs sit edge to edge in their order, whatever their widths")
    func placementsAreContiguous() {
        let run = EditorTabRunLayoutBuilder.run(
            forTrack: Self.wideTrack, count: 4, overflow: .scroll, preferredWidths: [nil, 310, nil, 290]
        )
        let frames = run.placements.sorted { $0.index < $1.index }.map(\.frame)

        #expect(frames.first?.minX == 0)
        for index in 1 ..< frames.count {
            #expect(Self.isClose(frames[index].minX, frames[index - 1].maxX))
        }
        #expect(Self.isClose(run.linearBoundaries.last ?? 0, run.contentSize.width))
        #expect(run.linearBoundaries.count == 5)
    }

    @Test("The other tabs give room only down to the minimum, and the growing tabs share what is left")
    func growingTabsShareWhenRoomRunsOut() {
        let track: CGFloat = 800
        let usable = track - EditorTabStripLayout.trackPadding * 2
        let run = EditorTabRunLayoutBuilder.run(
            forTrack: track, count: 6, overflow: .scroll, preferredWidths: [300, 300, nil, nil, nil, nil]
        )
        let widths = Self.widths(run)
        let minimum = EditorTabStripLayout.minimumTabWidth
        let grown = (usable - 4 * minimum) / 2

        #expect(Self.isClose(widths[0], grown))
        #expect(Self.isClose(widths[1], grown))
        #expect(widths[2 ... 5].allSatisfy { Self.isClose($0, minimum) })
        #expect(Self.isClose(run.contentSize.width, usable))
    }

    @Test("A located tab never grows past the maximum")
    func preferredWidthIsCapped() {
        let run = EditorTabRunLayoutBuilder.run(
            forTrack: Self.wideTrack, count: 7, overflow: .scroll, preferredWidths: [1_000, nil, nil, nil, nil, nil, nil]
        )
        #expect(Self.widths(run)[0] == EditorTabStripLayout.maximumLocatedTabWidth)
    }

    @Test("A tab asking for less than the room the others get never drops below what it asked for")
    func smallerRequestIsAFloor() {
        let run = EditorTabRunLayoutBuilder.run(
            forTrack: Self.wideTrack, count: 7, overflow: .scroll,
            preferredWidths: [150, 300, nil, nil, nil, nil, nil]
        )
        let widths = Self.widths(run)

        #expect(widths[0] == 150)
        #expect(widths[1] == 300)
        #expect(widths[2 ... 6].allSatisfy { Self.isClose($0, (Self.usable - 450) / 5) })
        #expect(Self.isClose(run.contentSize.width, Self.usable))
    }

    @Test("A full strip keeps every tab at the minimum and scrolls as it did")
    func fullStripScrollsAsBefore() {
        let plain = EditorTabRunLayoutBuilder.run(forTrack: 604, count: 12, overflow: .scroll)
        let located = EditorTabRunLayoutBuilder.run(
            forTrack: 604, count: 12, overflow: .scroll, preferredWidths: Array(repeating: 260, count: 12)
        )

        #expect(located == plain)
    }

    @Test("A wrapped strip keeps its equal widths")
    func wrappingIgnoresPreferredWidths() {
        let plain = EditorTabRunLayoutBuilder.run(forTrack: Self.wideTrack, count: 7, overflow: .rows)
        let located = EditorTabRunLayoutBuilder.run(
            forTrack: Self.wideTrack, count: 7, overflow: .rows, preferredWidths: [nil, 300, nil, 300, nil, nil, nil]
        )

        #expect(located == plain)
    }

    // MARK: - Reorder

    @Test("The reorder crosses a wide neighbour at its own centre, and the swap does not undo itself")
    func reorderUsesTheDrawnWidths() {
        let before: [CGFloat] = [0, 100, 400, 500]
        #expect(EditorTabReorderResolver.settledDestination(forLocation: 240, boundaries: before, currentIndex: 0) == nil)
        #expect(EditorTabReorderResolver.settledDestination(forLocation: 260, boundaries: before, currentIndex: 0) == 1)

        // The narrow tab now sits after the wide one, and the pointer has not come back past the wide one's centre.
        let after: [CGFloat] = [0, 300, 400, 500]
        #expect(EditorTabReorderResolver.settledDestination(forLocation: 260, boundaries: after, currentIndex: 1) == nil)
        #expect(EditorTabReorderResolver.settledDestination(forLocation: 140, boundaries: after, currentIndex: 1) == 0)
    }

    @Test("Equal boundaries answer exactly as the equal width does")
    func boundariesMatchTheEqualWidth() {
        let width: CGFloat = 120
        let boundaries = (0 ... 5).map { CGFloat($0) * width }
        for current in 0 ..< 5 {
            for location in stride(from: CGFloat(-50), through: 700, by: 7.5) {
                #expect(
                    EditorTabReorderResolver.settledDestination(
                        forLocation: location, boundaries: boundaries, currentIndex: current
                    ) == EditorTabReorderResolver.settledDestination(
                        forLocation: location, tabWidth: width, currentIndex: current, count: 5
                    )
                )
            }
        }
    }

    // MARK: - The strip's state

    @MainActor
    @Test("A preferred width reaches the run, and follows its tab through a reorder")
    func interactionCarriesWidthsWithTheirTabs() throws {
        let ids = (0 ..< 4).map { _ in UUID() }
        let interaction = EditorTabStripInteraction()
        interaction.adopt(tabIds: ids, overflow: .scroll)
        interaction.updateRun(trackWidth: Self.wideTrack, count: ids.count)

        interaction.setPreferredWidths([ids[0]: 310])
        #expect(interaction.run.placement(at: 0)?.frame.width == 310)

        interaction.beginReorder(of: ids[0])
        interaction.updateReorder(toLinearLocation: 2_000)
        let moved = try #require(interaction.displayedIds.firstIndex(of: ids[0]))
        #expect(moved == ids.count - 1)
        #expect(interaction.run.placement(at: moved)?.frame.width == 310)
        #expect(interaction.run.placement(at: 0)?.frame.width != 310)

        interaction.clearReorder()
        #expect(interaction.run.placement(at: 0)?.frame.width == 310)
    }

    // MARK: - What a tab asks for

    @MainActor
    @Test("Only a located title asks for a width, and it is wider than its text alone")
    func onlyLocatedTitlesAskForAWidth() throws {
        var table = QueryTab(title: "orders", tabType: .table, tableName: "orders")
        table.tableContext.databaseName = "shop_demo"
        let query = QueryTab(title: "Query 1", tabType: .query)
        let tabs = [table, query]

        let located = EditorTabLabelResolver.resolve(
            tabs: tabs, target: .database, style: .location(connectionName: "Shop Demo")
        )
        let widths = EditorTabStripLayout.preferredWidths(tabs: tabs, labels: located)
        let width = try #require(widths[table.id])
        #expect(widths[query.id] == nil)
        #expect(width > EditorTabStripLayout.textWidth("orders@shop_demo (Shop Demo)", isPreview: false))
        #expect(width <= EditorTabStripLayout.maximumLocatedTabWidth)

        let named = EditorTabLabelResolver.resolve(tabs: tabs, target: .database)
        #expect(EditorTabStripLayout.preferredWidths(tabs: tabs, labels: named).isEmpty)
    }

    @MainActor
    @Test("A longer title asks for more room, and a glyph adds its own")
    func naturalWidthGrowsWithItsParts() {
        let short = EditorTabLabelResolver.Label(text: "orders@shop (A)", description: "")
        let long = EditorTabLabelResolver.Label(text: "customer_orders@shop_demo (Shop Demo)", description: "")
        let glyph = EditorTabLabelResolver.Label(
            text: "orders@shop (A)", description: "", icon: ObjectIcon(symbolName: "tablecells")
        )

        let shortWidth = EditorTabStripLayout.naturalWidth(of: short, isPinned: false, isPreview: false)
        #expect(EditorTabStripLayout.naturalWidth(of: long, isPinned: false, isPreview: false) > shortWidth)
        #expect(EditorTabStripLayout.naturalWidth(of: glyph, isPinned: false, isPreview: false) > shortWidth)
        #expect(EditorTabStripLayout.naturalWidth(of: short, isPinned: true, isPreview: false) > shortWidth)
    }
}
