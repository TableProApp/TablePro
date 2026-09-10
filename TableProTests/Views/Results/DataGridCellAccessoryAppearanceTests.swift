//
//  DataGridCellAccessoryAppearanceTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@Suite("DataGridCell accessory appearance")
@MainActor
struct DataGridCellAccessoryAppearanceTests {
    private struct InkMetrics {
        let coverage: Double
        let brightness: Double
        let width: Double
        let height: Double
    }

    /// A cell is drawn rather than mounted, so this renders one through the renderer the grid uses
    /// and reads the accessory rect back off the bitmap. The text stays empty so only the accessory
    /// contributes ink.
    private final class RenderedCellView: NSView {
        var appearanceToDraw: DataGridCellAppearance?
        private let renderer = DataGridCellRenderer()
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            guard let appearanceToDraw else { return }
            renderer.draw(appearanceToDraw, in: bounds)
        }
    }

    private func makeCell(kind: DataGridCellKind, appearance: NSAppearance) -> NSView {
        let cell = RenderedCellView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        cell.appearance = appearance
        cell.appearanceToDraw = DataGridCellAppearance.resolve(
            kind: kind,
            content: DataGridCellContent(displayText: "", rawValue: "42", placeholder: nil),
            state: DataGridCellState(
                visualState: .empty,
                isFocused: false,
                isEditable: true,
                isLargeDataset: false,
                row: 0,
                columnIndex: 0
            ),
            palette: .placeholder,
            nullDisplayString: "NULL",
            onEmphasizedSelection: false,
            hasOverlay: false
        )
        return cell
    }

    private func accessoryInk(
        kind: DataGridCellKind,
        accessory: DataGridCellAccessory,
        appearanceName: NSAppearance.Name
    ) throws -> InkMetrics {
        let appearance = try #require(NSAppearance(named: appearanceName))
        let cell = makeCell(kind: kind, appearance: appearance)
        let rep = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: rep)
        #expect(rep.hasAlpha)

        let scale = max(1, rep.pixelsWide / Int(cell.bounds.width))
        let frame = accessory.frame(in: cell.bounds)

        var minX = Int.max
        var maxX = Int.min
        var minY = Int.max
        var maxY = Int.min
        var ink = 0
        var total = 0
        var brightnessSum = 0.0
        for y in Int(frame.minY) * scale ..< Int(frame.maxY) * scale {
            for x in Int(frame.minX) * scale ..< Int(frame.maxX) * scale {
                total += 1
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.1 else { continue }
                ink += 1
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                if let srgb = color.usingColorSpace(.sRGB) {
                    brightnessSum += (srgb.redComponent + srgb.greenComponent + srgb.blueComponent) / 3
                }
            }
        }
        guard ink > 0, total > 0 else {
            return InkMetrics(coverage: 0, brightness: 0, width: 0, height: 0)
        }
        return InkMetrics(
            coverage: Double(ink) / Double(total),
            brightness: brightnessSum / Double(ink),
            width: Double(maxX - minX + 1) / Double(scale),
            height: Double(maxY - minY + 1) / Double(scale)
        )
    }

    /// Asserting the direction of the change, not just that it changed. Inequality alone still
    /// passes if the two appearances are ever served each other's bitmap.
    private func expectFollowsAppearance(
        kind: DataGridCellKind,
        accessory: DataGridCellAccessory
    ) throws {
        let light = try accessoryInk(kind: kind, accessory: accessory, appearanceName: .aqua)
        let dark = try accessoryInk(kind: kind, accessory: accessory, appearanceName: .darkAqua)

        #expect(light.coverage > 0.05)
        #expect(dark.coverage > 0.05)
        #expect(light.brightness < 0.5)
        #expect(dark.brightness > 0.5)
    }

    @Test("The foreign key arrow takes its colour from the light appearance")
    func foreignKeyArrowFollowsAppearance() throws {
        try expectFollowsAppearance(kind: .foreignKey, accessory: .foreignKey)
    }

    @Test("The chevron takes its colour from the appearance too")
    func chevronFollowsAppearance() throws {
        try expectFollowsAppearance(kind: .json, accessory: .chevron)
    }

    /// The glyph cache is process-wide, and nothing orders this against the tests above or against
    /// any other suite that renders a cell, so this cannot observe a genuine first draw. What it
    /// does check is that reading dark before light gives the same answer as the reverse.
    @Test("Rendering order does not change what either appearance gets")
    func renderingIsOrderIndependent() throws {
        let darkFirst = try accessoryInk(kind: .foreignKey, accessory: .foreignKey, appearanceName: .darkAqua)
        let lightSecond = try accessoryInk(kind: .foreignKey, accessory: .foreignKey, appearanceName: .aqua)

        #expect(darkFirst.brightness > 0.5)
        #expect(lightSecond.brightness < 0.5)
    }

    /// Stretching the chevron to fill its 12 x 14 rect measures 9.0pt wide, drawing it at its own
    /// 9 x 12 point size measures 6.5pt.
    @Test("The chevron draws at its own size instead of stretching to fill its rect")
    func chevronKeepsItsNaturalWidth() throws {
        let ink = try accessoryInk(kind: .json, accessory: .chevron, appearanceName: .darkAqua)

        #expect(ink.width > 4)
        #expect(ink.width <= 8)
    }

    /// The bare arrow covers 0.097 of the accessory rect and measures 11 x 9. Any enclosing shape
    /// takes it back to the circled variant's square 14 x 14 at 0.255, and a filled badge to 0.594.
    @Test("The foreign key accessory is a bare arrow with nothing drawn around it")
    func foreignKeyArrowHasNoEnclosingShape() throws {
        let ink = try accessoryInk(kind: .foreignKey, accessory: .foreignKey, appearanceName: .darkAqua)

        #expect(ink.coverage > 0.05)
        #expect(ink.coverage < 0.18)
        #expect(ink.width > ink.height)
        #expect(ink.width <= 12)
    }
}
