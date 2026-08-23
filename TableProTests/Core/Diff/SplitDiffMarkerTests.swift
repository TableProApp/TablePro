//
//  SplitDiffMarkerTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

@Suite("Split diff marker")
struct SplitDiffMarkerTests {
    @Test("A removed line is marked only on the before side")
    func removedMarksBeforeOnly() {
        #expect(SplitDiffMarker.resolve(kind: .removed, side: .before) == .removed)
        #expect(SplitDiffMarker.resolve(kind: .removed, side: .after) == nil)
    }

    @Test("An added line is marked only on the after side")
    func addedMarksAfterOnly() {
        #expect(SplitDiffMarker.resolve(kind: .added, side: .after) == .added)
        #expect(SplitDiffMarker.resolve(kind: .added, side: .before) == nil)
    }

    @Test("A changed line is marked on both sides")
    func changedMarksBothSides() {
        #expect(SplitDiffMarker.resolve(kind: .changed, side: .before) == .changed)
        #expect(SplitDiffMarker.resolve(kind: .changed, side: .after) == .changed)
    }

    @Test("An unchanged line carries no marker")
    func unchangedHasNoMarker() {
        #expect(SplitDiffMarker.resolve(kind: .unchanged, side: .before) == nil)
        #expect(SplitDiffMarker.resolve(kind: .unchanged, side: .after) == nil)
    }

    @Test("Every marker has a distinct glyph and label")
    func markersAreDistinct() {
        let markers: [SplitDiffMarker] = [.added, .removed, .changed]
        #expect(Set(markers.map(\.glyph)).count == markers.count)
        #expect(Set(markers.map(\.label)).count == markers.count)
        #expect(markers.map(\.label).contains(SplitDiffMarker.unchangedLabel) == false)
    }
}
