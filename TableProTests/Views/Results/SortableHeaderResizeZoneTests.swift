//
//  SortableHeaderResizeZoneTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
@Suite("SortableHeaderView resize zone detection")
struct SortableHeaderResizeZoneTests {
    @Test("Point on column edge is inside resize zone")
    func pointOnEdgeIsInside() {
        let edges: [CGFloat] = [60, 220, 380]
        #expect(SortableHeaderView.isInResizeZone(point: NSPoint(x: 60, y: 8), columnEdges: edges))
        #expect(SortableHeaderView.isInResizeZone(point: NSPoint(x: 220, y: 8), columnEdges: edges))
    }

    @Test("Point within zoneWidth of an edge is inside resize zone")
    func pointNearEdgeIsInside() {
        let edges: [CGFloat] = [100]
        #expect(SortableHeaderView.isInResizeZone(point: NSPoint(x: 96, y: 8), columnEdges: edges))
        #expect(SortableHeaderView.isInResizeZone(point: NSPoint(x: 104, y: 8), columnEdges: edges))
    }

    @Test("Point outside zoneWidth of every edge is not in resize zone")
    func pointFarFromEdgeIsOutside() {
        let edges: [CGFloat] = [100, 200]
        #expect(!SortableHeaderView.isInResizeZone(point: NSPoint(x: 50, y: 8), columnEdges: edges))
        #expect(!SortableHeaderView.isInResizeZone(point: NSPoint(x: 150, y: 8), columnEdges: edges))
        #expect(!SortableHeaderView.isInResizeZone(point: NSPoint(x: 250, y: 8), columnEdges: edges))
    }

    @Test("Empty edge list never matches")
    func emptyEdgesNeverMatches() {
        #expect(!SortableHeaderView.isInResizeZone(point: NSPoint(x: 0, y: 0), columnEdges: []))
        #expect(!SortableHeaderView.isInResizeZone(point: NSPoint(x: 100, y: 0), columnEdges: []))
    }

    @Test("Custom zone width widens the match band")
    func customZoneWidthWidensBand() {
        let edges: [CGFloat] = [100]
        #expect(!SortableHeaderView.isInResizeZone(
            point: NSPoint(x: 92, y: 0),
            columnEdges: edges
        ))
        #expect(SortableHeaderView.isInResizeZone(
            point: NSPoint(x: 92, y: 0),
            columnEdges: edges,
            zoneWidth: 8
        ))
    }
}
