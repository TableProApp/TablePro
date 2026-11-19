//
//  EditorTabRunLayoutTests.swift
//  TableProTests
//

import CoreGraphics
import Foundation
@testable import TablePro
import Testing

struct EditorTabRunLayoutTests {
    private static let minimum = EditorTabStripLayout.minimumTabWidth

    @Test("Tabs that fit share the viewport equally and do not scroll")
    func tabsThatFitShareTheViewport() {
        let run = EditorTabRunLayout(viewportWidth: 1_180, count: 4)

        #expect(run.tabWidth == 295)
        #expect(run.contentWidth == 1_180)
        #expect(run.maximumOffset == 0)
        #expect(run.frames(offset: 0).map(\.width) == [295, 295, 295, 295])
    }

    @Test("Tabs stop shrinking at the minimum and the content runs past the viewport")
    func crowdedTabsScroll() {
        let run = EditorTabRunLayout(viewportWidth: 600, count: 10)

        #expect(run.tabWidth == Self.minimum)
        #expect(run.contentWidth == Self.minimum * 10)
        #expect(run.maximumOffset == Self.minimum * 10 - 600)
    }

    @Test("An empty run has no frames and nowhere to scroll")
    func emptyRun() {
        let run = EditorTabRunLayout(viewportWidth: 600, count: 0)

        #expect(run.frames(offset: 0).isEmpty)
        #expect(run.maximumOffset == 0)
    }

    @Test("Neighbouring tabs share an edge at every offset", arguments: [0, 137, 480, 1_000] as [CGFloat])
    func tabsLeaveNoGaps(offset: CGFloat) {
        let frames = EditorTabRunLayout(viewportWidth: 600, count: 14).frames(offset: offset)

        for (leading, trailing) in zip(frames, frames.dropFirst()) {
            #expect(leading.maxX == trailing.minX)
        }
    }

    @Test("Every tab stays inside the viewport while the run scrolls", arguments: [0, 137, 480, 1_080] as [CGFloat])
    func tabsStayInsideTheViewport(offset: CGFloat) {
        let run = EditorTabRunLayout(viewportWidth: 600, count: 14)
        let origin = run.clamped(offset: offset)

        for frame in run.frames(offset: offset) {
            #expect(frame.minX >= origin - 1)
            #expect(frame.maxX <= origin + 600 + 1)
        }
    }

    @Test("Tabs past the trailing edge narrow as they get further away")
    func trailingTabsCollapse() {
        let widths = EditorTabRunLayout(viewportWidth: 1_180, count: 20).frames(offset: 0).map(\.width)

        #expect(widths.prefix(6).allSatisfy { $0 == Self.minimum })
        #expect(widths.allSatisfy { $0 <= Self.minimum })
        // Edges land on whole points, so two far tabs can differ by one point either way.
        let collapsing = Array(widths.dropFirst(7))
        for (nearer, further) in zip(collapsing, collapsing.dropFirst()) {
            #expect(further <= nearer + 1)
        }
        #expect(widths.last ?? Self.minimum < Self.minimum / 2)
    }

    @Test("Collapsed tabs fill the viewport up to its edge", arguments: [16, 40, 120])
    func collapsedTabsReachTheEdge(count: Int) {
        let run = EditorTabRunLayout(viewportWidth: 1_180, count: count)

        #expect(run.frames(offset: 0).last?.maxX == 1_180)

        let end = run.maximumOffset
        #expect(run.frames(offset: end).first?.minX == end)
    }

    @Test("A point on a collapsed tab resolves to that tab's slot")
    func collapsedTabResolvesToItsSlot() {
        let run = EditorTabRunLayout(viewportWidth: 600, count: 10)
        let frames = run.frames(offset: 0)

        for index in frames.indices where frames[index].width > 1 {
            let location = run.slotLocation(ofContentX: frames[index].midX, offset: 0)
            #expect(Int(location / run.tabWidth) == index, "tab \(index) resolved to \(location)")
        }
    }

    @Test("Slots match the drawn run where nothing is collapsed")
    func uniformRunMapsToItself() {
        let run = EditorTabRunLayout(viewportWidth: 1_200, count: 4)

        #expect(run.slotLocation(ofContentX: 450, offset: 0) == 450)
    }

    @Test("A point past either end resolves to that end of the run")
    func pointsPastTheEndsClamp() {
        let run = EditorTabRunLayout(viewportWidth: 600, count: 10)

        #expect(run.slotLocation(ofContentX: -20, offset: 0) == 0)
        #expect(run.slotLocation(ofContentX: 5_000, offset: 0) == run.contentWidth)
    }

    @Test("The first tab is full width at the start and the last one at the end")
    func edgesAreFullWidthAtTheirEnds() {
        let run = EditorTabRunLayout(viewportWidth: 600, count: 14)

        #expect(run.frames(offset: 0).first?.width == Self.minimum)
        #expect(run.frames(offset: run.maximumOffset).last?.width == Self.minimum)
    }

    @Test("An elastic overscroll lays out as the nearest real offset")
    func overscrollClamps() {
        let run = EditorTabRunLayout(viewportWidth: 600, count: 14)

        #expect(run.frames(offset: -40) == run.frames(offset: 0))
        #expect(run.frames(offset: run.maximumOffset + 40) == run.frames(offset: run.maximumOffset))
    }

    @Test("Revealing a tab shows it at full width from either side", arguments: [0, 5, 13])
    func revealShowsTheTab(index: Int) {
        let run = EditorTabRunLayout(viewportWidth: 800, count: 14)

        for start in [0, run.maximumOffset / 2, run.maximumOffset] {
            let offset = run.revealOffset(forTabAt: index, from: start)
            #expect(run.frames(offset: offset)[index].width == Self.minimum)
        }
    }

    @Test("A tab already showing does not move the run")
    func revealLeavesAVisibleTabAlone() {
        let run = EditorTabRunLayout(viewportWidth: 1_200, count: 14)
        let offset = run.maximumOffset / 2
        let index = Int((offset + 600) / run.tabWidth)

        #expect(run.revealOffset(forTabAt: index, from: offset) == offset)
    }

    @Test("A run that fits never scrolls to reveal")
    func revealOnARunThatFits() {
        let run = EditorTabRunLayout(viewportWidth: 1_200, count: 4)

        #expect(run.revealOffset(forTabAt: 3, from: 0) == 0)
    }
}
