//
//  WorkspaceRailCellRenderingTests.swift
//  TableProTests
//
//  The rail shipped a full-width saturated slab behind its label once, which no assertion caught
//  because every test read model state and none of them looked at the cell. These render the cell
//  and read pixels back.
//
//  A free-standing cell is not enough either. A source list restyles a cell's `textField` and pads
//  its rows on layout, so the container line shipped clipped while every free-standing assertion
//  passed (#3244). Geometry is read from cells hosted in the strip's own table.
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct WorkspaceRailCellRenderingTests {
    private static let layout = WorkspaceRailMetrics.medium

    private static let layouts = [
        WorkspaceRailMetrics.small,
        WorkspaceRailMetrics.medium,
        WorkspaceRailMetrics.large,
    ]

    private func entry(
        name: String = "production",
        container: String = "app",
        color: ConnectionColor = .none,
        status: ConnectionStatus = .connected
    ) -> WorkspaceRailEntry {
        var connection = TestFixtures.makeConnection(database: container)
        connection.name = name
        connection.color = color
        return WorkspaceRailEntry(
            workspace: WorkspaceID(connectionId: connection.id, container: container),
            connection: connection,
            status: status,
            containerTarget: .database
        )
    }

    /// Pinned to the light appearance so the ink and colour counters read the same on any Mac.
    private func cell(
        name: String = "production",
        container: String = "app",
        color: ConnectionColor,
        status: ConnectionStatus = .connected,
        layout: WorkspaceRailMetrics.Layout = WorkspaceRailMetrics.medium
    ) -> WorkspaceRailCellView {
        let view = WorkspaceRailCellView(frame: NSRect(
            x: 0, y: 0, width: layout.width, height: WorkspaceRailCellView.rowHeight(for: layout)
        ))
        view.appearance = NSAppearance(named: .aqua)
        view.configure(entry: entry(name: name, container: container, color: color, status: status), layout: layout)
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
        let label = try #require(view.renderedLabel)
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

    @Test("The identity dot never touches the label, at every rail size")
    func identityDotClearsTheLabel() throws {
        for layout in Self.layouts {
            let rail = HostedRail(entries: [entry(name: "podo-stage", container: "gwatop", color: .red)], layout: layout)
            let cell = try rail.cell(atRow: 0)
            let label = try #require(cell.renderedLabel)
            let icon = try #require(cell.imageView)
            let dot = try #require(cell.subviews.first { $0 !== label && $0 !== icon })

            #expect(cell.bounds.contains(label.frame), "label escaped the \(layout) row")
            #expect(cell.bounds.contains(dot.frame), "identity dot escaped the \(layout) row")
            #expect(!dot.frame.intersects(label.frame), "identity dot overlapped the label in \(layout)")
        }
    }

    /// The defect behind "1…": the table rewrote both lines to one 13pt run, which needs more height
    /// than the row had, so the container line was compressed away.
    @Test("The strip's table leaves each label line its own font and colour")
    func hostedLabelKeepsItsOwnRuns() throws {
        for layout in Self.layouts {
            for selectedRow in [nil, 0] as [Int?] {
                let rail = HostedRail(
                    entries: [entry(name: "podo-stage", container: "gwatop")],
                    layout: layout,
                    selectedRow: selectedRow
                )
                let value = try #require(try rail.cell(atRow: 0).renderedLabel).attributedStringValue
                let last = value.length - 1
                let primary = value.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                let secondary = value.attribute(.font, at: last, effectiveRange: nil) as? NSFont
                let secondaryColor = value.attribute(.foregroundColor, at: last, effectiveRange: nil) as? NSColor

                #expect(value.string == "podo-stage\ngwatop")
                #expect(primary?.pointSize == layout.fontSize, "primary line restyled in \(layout)")
                #expect(
                    secondary?.pointSize == WorkspaceRailCellView.secondaryFontSize(for: layout.fontSize),
                    "container line restyled in \(layout)"
                )
                #expect(secondaryColor == .secondaryLabelColor, "container line lost its colour in \(layout)")
            }
        }
    }

    @Test("Two label lines are laid out at their full height in the strip's table")
    func hostedLabelIsNeverSqueezed() throws {
        for layout in Self.layouts {
            for selectedRow in [nil, 0] as [Int?] {
                let rail = HostedRail(
                    entries: [entry(name: "a-very-long-production-connection", container: "a_very_long_database")],
                    layout: layout,
                    selectedRow: selectedRow
                )
                let cell = try rail.cell(atRow: 0)
                let label = try #require(cell.renderedLabel)

                #expect(
                    label.frame.height >= label.intrinsicContentSize.height - 0.5,
                    "label squeezed to \(label.frame.height) of \(label.intrinsicContentSize.height) in \(layout)"
                )
                #expect(cell.bounds.contains(label.frame), "label escaped the \(layout) row")
            }
        }
    }

    /// The selection fill covers the whole row, so the cell's own edges are the fill's, and the
    /// padding inside them is all that separates one tile from the next. Centring an odd number of
    /// points snaps to whole pixels on a 1x display, so the two sides may differ by one pixel there.
    @Test("A tile has as much space above its glyph as below its label")
    func hostedTileIsBalanced() throws {
        let cases: [(String, ConnectionStatus)] = [
            ("gwatop", .connected), ("", .connected), ("gwatop", .error("refused")), ("gwatop", .disconnected),
        ]
        for layout in Self.layouts {
            for (container, status) in cases {
                let rail = HostedRail(
                    entries: [entry(name: "podo-stage", container: container, status: status)],
                    layout: layout
                )
                let cell = try rail.cell(atRow: 0)
                let rowView = try #require(rail.table.rowView(atRow: 0, makeIfNecessary: false))
                let margins = try verticalMargins(of: cell)

                #expect(abs(cell.frame.height - rowView.frame.height) < 0.5, "the fill is taller than the tile")
                #expect(
                    abs(margins.top - margins.bottom) <= rail.pixel + 0.001,
                    "\(margins.top)pt above the glyph, \(margins.bottom)pt below the label in \(layout)"
                )
                if !container.isEmpty {
                    #expect(abs(margins.top - layout.padding) <= rail.pixel + 0.001, "two-line tile padding in \(layout)")
                }
            }
        }
    }

    @Test("The glyph and its label sit the same distance apart with or without a colour dot")
    func hostedGapIgnoresTheDot() throws {
        for layout in Self.layouts {
            for color in [ConnectionColor.none, .red] {
                let rail = HostedRail(entries: [entry(container: "app", color: color)], layout: layout)
                let cell = try rail.cell(atRow: 0)
                let glyph = try glyphRect(in: cell)
                let label = try #require(cell.renderedLabel)
                let gap = cell.isFlipped ? label.frame.minY - glyph.maxY : glyph.minY - label.frame.maxY

                #expect(abs(gap - WorkspaceRailMetrics.iconLabelGap) <= 0.5, "gap \(gap) in \(layout), \(color)")
            }
        }
    }

    /// The label left the `textField` outlet, which is where the default drag image finds it. Like
    /// AppKit's own, it is drawn in the normal style from the selected row too, or it would be white
    /// on a clear image over a light window.
    @Test("Dragging an entry carries its label, legible whether or not the entry is selected")
    func dragImageCarriesTheLabel() throws {
        for style in [NSView.BackgroundStyle.normal, .emphasized] {
            let view = cell(color: .none)
            view.backgroundStyle = style
            let label = try #require(view.renderedLabel)
            let component = try #require(view.draggingImageComponents.first { $0.key == .label })
            let image = try #require(component.contents as? NSImage)
            let data = try #require(image.tiffRepresentation)
            let rep = try #require(NSBitmapImageRep(data: data))

            #expect(component.frame == view.convert(label.bounds, from: label))
            #expect(view.draggingImageComponents.contains { $0.key == .icon })
            #expect(pixelCount(rep, matching: isInk) > 0, "drag label has no dark ink in the \(style) style")
            #expect(label.cell?.backgroundStyle == style, "drawing the drag image left the row restyled")
        }
    }

    /// The glyph as Auto Layout places it. SF Symbols carry alignment insets, so the warning and
    /// disconnected glyphs' frames reach past the box the layout centres.
    private func glyphRect(in cell: WorkspaceRailCellView) throws -> NSRect {
        let icon = try #require(cell.imageView)
        return icon.alignmentRect(forFrame: icon.frame)
    }

    private func verticalMargins(of cell: WorkspaceRailCellView) throws -> (top: CGFloat, bottom: CGFloat) {
        let glyph = try glyphRect(in: cell)
        let label = try #require(cell.renderedLabel)
        guard cell.isFlipped else {
            return (cell.bounds.maxY - glyph.maxY, label.frame.minY - cell.bounds.minY)
        }
        return (glyph.minY - cell.bounds.minY, cell.bounds.maxY - label.frame.maxY)
    }

    @Test("The scroll geometry puts every row where the strip's table puts it")
    func scrollGeometryMatchesTheTable() throws {
        for layout in Self.layouts {
            let entries = (0 ..< 12).map { entry(name: "connection \($0)", container: "db\($0)") }
            let rail = HostedRail(entries: entries, layout: layout)
            let geometry = rail.table.scrollGeometry(viewportHeight: 300)

            #expect(geometry.rowCount == 12)
            for row in 0 ..< 12 {
                let rect = rail.table.rect(ofRow: row)
                #expect(abs(geometry.top(ofRow: row) - rect.minY) < 0.001, "row \(row) top in \(layout)")
                #expect(abs(geometry.top(ofRow: row) + geometry.rowHeight - rect.maxY) < 0.001)
            }
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

    /// A frame inside the row proves nothing about the text inside the frame. The way this fails is
    /// the second line laying out and never being drawn. The one-line cell is the control: it is
    /// centred, so the container line has to reach below where the connection name on its own stops.
    @Test("The container line is painted below the connection line at every rail size")
    func containerLinePaintsBelowConnectionLine() throws {
        for layout in Self.layouts {
            let oneLineRail = HostedRail(entries: [entry(name: "podo-stage", container: "")], layout: layout)
            let twoLineRail = HostedRail(entries: [entry(name: "podo-stage", container: "gwatop")], layout: layout)
            let oneLine = try #require(render(try oneLineRail.cell(atRow: 0)))
            let twoLines = try #require(render(try twoLineRail.cell(atRow: 0)))

            let connectionOnly = try #require(lowestInkRow(oneLine))
            let withContainer = try #require(lowestInkRow(twoLines))

            #expect(
                withContainer > connectionOnly,
                "the container line was clipped away in the \(layout) row"
            )
        }
    }
}

/// The strip's own table in a window, holding real cells. Never closed, only released: closing a
/// window inside the test host can take the host down.
@MainActor
private final class HostedRail: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = WorkspaceRailTableView()
    private let window: NSWindow
    private let entries: [WorkspaceRailEntry]
    private let layout: WorkspaceRailMetrics.Layout
    private let rowHeight: CGFloat

    init(entries: [WorkspaceRailEntry], layout: WorkspaceRailMetrics.Layout, selectedRow: Int? = nil) {
        self.entries = entries
        self.layout = layout
        rowHeight = WorkspaceRailCellView.rowHeight(for: layout)
        let frame = NSRect(x: 0, y: 0, width: layout.width, height: 600)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        super.init()

        let scrollView = NSScrollView(frame: frame)
        scrollView.documentView = table
        window.contentView = scrollView
        table.dataSource = self
        table.delegate = self
        table.reloadData()
        table.sizeLastColumnToFit()
        if let selectedRow {
            table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        }
        scrollView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// One device pixel in points, the finest step Auto Layout places a frame on.
    var pixel: CGFloat {
        1 / max(1, window.backingScaleFactor)
    }

    func cell(atRow row: Int) throws -> WorkspaceRailCellView {
        try #require(table.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkspaceRailCellView)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = WorkspaceRailCellView(frame: .zero)
        cell.configure(entry: entries[row], layout: layout)
        return cell
    }
}
