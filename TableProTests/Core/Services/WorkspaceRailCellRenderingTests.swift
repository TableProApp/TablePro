//
//  WorkspaceRailCellRenderingTests.swift
//  TableProTests
//
//  The rail shipped a full-width saturated slab behind its label once, which no assertion caught
//  because every test read model state and none of them looked at the cell. These render the cell
//  and read pixels back.
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@Suite("Workspace rail cell rendering")
@MainActor
struct WorkspaceRailCellRenderingTests {
    private static let layout = WorkspaceRailMetrics.medium

    private func cell(
        name: String = "production",
        container: String = "app",
        color: ConnectionColor,
        status: ConnectionStatus = .connected,
        layout: WorkspaceRailMetrics.Layout = WorkspaceRailMetrics.medium
    ) -> WorkspaceRailCellView {
        var connection = TestFixtures.makeConnection(database: container)
        connection.name = name
        connection.color = color
        let entry = WorkspaceRailEntry(
            workspace: WorkspaceID(connectionId: connection.id, container: container),
            connection: connection,
            status: status,
            containerTarget: .database
        )

        let view = WorkspaceRailCellView(frame: NSRect(
            x: 0, y: 0, width: layout.width, height: layout.rowHeight
        ))
        view.configure(entry: entry, layout: layout)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        return view
    }

    /// Measured: `cacheDisplay` does capture a layer-backed subview, and `CALayer.render(in:)`
    /// returns an empty bitmap for this tree whether or not the root is layer-backed.
    private func render(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func pixelCount(_ rep: NSBitmapImageRep, matching predicate: (NSColor) -> Bool) -> Int {
        pixelCount(
            rep,
            in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh),
            matching: predicate
        )
    }

    private func pixelCount(
        _ rep: NSBitmapImageRep,
        in rect: NSRect,
        matching predicate: (NSColor) -> Bool
    ) -> Int {
        var count = 0
        let xRange = max(0, Int(rect.minX)) ..< min(rep.pixelsWide, Int(ceil(rect.maxX)))
        let yRange = max(0, Int(rect.minY)) ..< min(rep.pixelsHigh, Int(ceil(rect.maxY)))
        for y in yRange {
            for x in xRange {
                guard let raw = rep.colorAt(x: x, y: y),
                      let color = raw.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.5 else { continue }
                if predicate(color) { count += 1 }
            }
        }
        return count
    }

    private func differingPixelCount(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else { return .max }
        var count = 0
        for y in 0 ..< lhs.pixelsHigh {
            for x in 0 ..< lhs.pixelsWide where lhs.colorAt(x: x, y: y) != rhs.colorAt(x: x, y: y) {
                count += 1
            }
        }
        return count
    }

    private func bitmapRect(_ viewRect: NSRect, in view: NSView, rep: NSBitmapImageRep) -> NSRect {
        let scaleX = CGFloat(rep.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / view.bounds.height
        return NSRect(
            x: viewRect.minX * scaleX,
            y: (view.bounds.maxY - viewRect.maxY) * scaleY,
            width: viewRect.width * scaleX,
            height: viewRect.height * scaleY
        )
    }

    private func isRedish(_ color: NSColor) -> Bool {
        color.redComponent > 0.55 && color.greenComponent < 0.45 && color.blueComponent < 0.45
    }

    private func isSelectedText(_ color: NSColor) -> Bool {
        color.redComponent > 0.75 && color.greenComponent > 0.75 && color.blueComponent > 0.75
    }

    private func isInk(_ color: NSColor) -> Bool {
        color.brightnessComponent < 0.6
    }

    /// The defect this suite exists for. The band covered the label's whole width; a dot may not
    /// cover more than a small fraction of the cell, whatever colour the user picks.
    @Test("The identity colour never covers more than a fraction of the cell")
    func identityStaysSmall() throws {
        let view = cell(color: .red)
        let rep = try #require(render(view))
        let total = rep.pixelsWide * rep.pixelsHigh
        let painted = pixelCount(rep, matching: isRedish)

        #expect(painted > 0, "the identity colour did not render at all")
        #expect(
            Double(painted) / Double(total) < 0.05,
            "identity covers \(painted) of \(total) pixels, which is a fill rather than a dot"
        )
    }

    /// The rail used to drop identity entirely on the selected row, which is the row whose identity
    /// the user most needs to confirm.
    @Test("The identity colour survives selection")
    func identitySurvivesSelection() throws {
        let view = cell(color: .red)
        view.backgroundStyle = .emphasized
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try #require(render(view))

        #expect(pixelCount(rep, matching: isRedish) > 0, "identity vanished on the selected row")
    }

    @Test("Both identity lines adapt to the selected-row foreground")
    func labelLinesAdaptToSelection() throws {
        let view = cell(color: .none)
        view.backgroundStyle = .emphasized
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try #require(render(view))
        let label = try #require(view.textField)
        let primaryInView = NSRect(
            x: label.frame.minX,
            y: label.frame.midY,
            width: label.frame.width,
            height: label.frame.height / 2
        )
        let secondaryInView = NSRect(
            x: label.frame.minX,
            y: label.frame.minY,
            width: label.frame.width,
            height: label.frame.height / 2
        )
        let primary = bitmapRect(primaryInView, in: view, rep: rep)
        let secondary = bitmapRect(secondaryInView, in: view, rep: rep)

        #expect(pixelCount(rep, in: primary, matching: isSelectedText) > 0)
        #expect(pixelCount(rep, in: secondary, matching: isSelectedText) > 0)
    }

    @Test("A connection with no colour paints no identity")
    func uncolouredPaintsNothing() throws {
        let view = cell(color: .none)
        let rep = try #require(render(view))

        #expect(pixelCount(rep, matching: isRedish) == 0)
    }

    @Test("Connections with one container keep visibly different identities")
    func duplicateContainersKeepVisibleConnectionIdentity() throws {
        let production = try #require(render(cell(
            name: "podo-prod", container: "gwatop", color: .none
        )))
        let staging = try #require(render(cell(
            name: "podo-stage", container: "gwatop", color: .none
        )))

        #expect(
            differingPixelCount(production, staging) > 100,
            "different connections rendered as the same rail entry"
        )
    }

    @Test("Two label lines fit every rail size without touching the identity dot")
    func labelFitsEveryLayout() throws {
        for layout in [WorkspaceRailMetrics.small, WorkspaceRailMetrics.medium, WorkspaceRailMetrics.large] {
            let view = cell(
                name: "podo-stage", container: "gwatop", color: .red,
                layout: layout
            )
            let label = try #require(view.textField)
            let icon = try #require(view.imageView)
            let dot = try #require(view.subviews.first { $0 !== label && $0 !== icon })

            #expect(view.bounds.contains(label.frame), "label escaped the \(layout) row")
            #expect(dot.frame.minY >= label.frame.maxY, "identity dot overlapped the label in \(layout)")
        }
    }

    /// The lowest row of the cell any text reaches. Read against the same cell carrying one line,
    /// it is the only evidence that the second line was drawn rather than laid out and clipped.
    ///
    /// The alpha floor is deliberately low: the container line is `secondaryLabelColor`, which is
    /// half-transparent by definition, so the 0.5 gate the colour counters use would read the whole
    /// second line as empty background.
    private func lowestInkRow(_ rep: NSBitmapImageRep) -> Int? {
        for y in stride(from: rep.pixelsHigh - 1, through: 0, by: -1) {
            for x in 0 ..< rep.pixelsWide {
                guard let raw = rep.colorAt(x: x, y: y),
                      let color = raw.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.1, isInk(color) else { continue }
                return y
            }
        }
        return nil
    }

    /// A frame inside the row proves nothing about the text inside the frame. The row height, the
    /// icon's own offset and the two font sizes are four numbers that have to add up, and the way
    /// they fail is the second line laying out and never being drawn, which `labelFitsEveryLayout`
    /// reads as a pass. The one-line cell is the control: the container line has to reach below
    /// where the connection name on its own stops.
    @Test("The container line is painted below the connection line at every rail size")
    func containerLinePaintsBelowConnectionLine() throws {
        for layout in [WorkspaceRailMetrics.small, WorkspaceRailMetrics.medium, WorkspaceRailMetrics.large] {
            let oneLine = try #require(render(cell(
                name: "podo-stage", container: "", color: .none, layout: layout
            )))
            let twoLines = try #require(render(cell(
                name: "podo-stage", container: "gwatop", color: .none, layout: layout
            )))

            let connectionOnly = try #require(lowestInkRow(oneLine))
            let withContainer = try #require(lowestInkRow(twoLines))

            #expect(
                withContainer > connectionOnly,
                "the container line was clipped away in the \(layout.rowHeight)pt row"
            )
        }
    }
}
