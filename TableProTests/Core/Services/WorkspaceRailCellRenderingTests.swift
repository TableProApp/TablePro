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

    private func cell(color: ConnectionColor, status: ConnectionStatus = .connected) -> WorkspaceRailCellView {
        var connection = TestFixtures.makeConnection(database: "app")
        connection.name = "production"
        connection.color = color
        let entry = WorkspaceRailEntry(
            workspace: WorkspaceID(connectionId: connection.id, container: "app"),
            connection: connection,
            status: status,
            containerTarget: .database
        )

        let view = WorkspaceRailCellView(frame: NSRect(
            x: 0, y: 0, width: Self.layout.width, height: Self.layout.rowHeight
        ))
        view.configure(entry: entry, layout: Self.layout)
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
        var count = 0
        for y in 0 ..< rep.pixelsHigh {
            for x in 0 ..< rep.pixelsWide {
                guard let raw = rep.colorAt(x: x, y: y),
                      let color = raw.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.5 else { continue }
                if predicate(color) { count += 1 }
            }
        }
        return count
    }

    private func isRedish(_ color: NSColor) -> Bool {
        color.redComponent > 0.55 && color.greenComponent < 0.45 && color.blueComponent < 0.45
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

    @Test("A connection with no colour paints no identity")
    func uncolouredPaintsNothing() throws {
        let view = cell(color: .none)
        let rep = try #require(render(view))

        #expect(pixelCount(rep, matching: isRedish) == 0)
    }
}
