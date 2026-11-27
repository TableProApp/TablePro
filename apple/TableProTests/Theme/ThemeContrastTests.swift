import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProTheme
import Testing

@MainActor
struct ThemeContrastTests {
    private static func bundledThemes() throws -> [ThemeDefinition] {
        try (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(ThemeDefinition.builtInPrefix) }
            .map { try ThemeFileFormat.decode(try Data(contentsOf: $0)) }
    }

    // The system's secondary label is 3.95:1 on white, under 4.5:1 on every light window: WCAG's 3:1 secondary floor.
    private static let lightSecondaryContrast: CGFloat = 3

    // secondaryLabelColor is translucent, so what the eye reads is the label over the fill.
    private static func composite(_ foreground: NSColor, over background: NSColor) -> NSColor {
        let alpha = foreground.alphaComponent
        return NSColor(
            srgbRed: foreground.redComponent * alpha + background.redComponent * (1 - alpha),
            green: foreground.greenComponent * alpha + background.greenComponent * (1 - alpha),
            blue: foreground.blueComponent * alpha + background.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    private static func contrast(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let first = lhs.relativeLuminance
        let second = rhs.relativeLuminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    @Test("The secondary label stays legible on every bundled window background")
    func secondaryLabelOnWindowBackground() throws {
        let themed = try Self.bundledThemes().filter { $0.isOverridden(.windowBackdrop) }
        #expect(themed.count >= 2, "Expected Dracula and Nord to set a window background")

        for theme in themed {
            let appearance = try #require(NSAppearance(named: theme.appearance == .dark ? .darkAqua : .aqua))
            var label: NSColor?
            var background: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                label = NSColor.secondaryLabelColor.usingColorSpace(.sRGB)
                background = theme.color(for: .windowBackdrop, in: appearance).usingColorSpace(.sRGB)
            }
            let secondary = try #require(label)
            let fill = try #require(background)
            let ratio = Self.contrast(Self.composite(secondary, over: fill), fill)
            let bar = theme.appearance == .dark ? Color.minimumLabelContrast : Self.lightSecondaryContrast

            #expect(ratio >= bar, "\(theme.id): \(ratio), bar \(bar)")
        }
    }

    // MARK: - Value colors

    private static let valueSlots = ThemeSlotSection.values.slots.filter { $0 != .gridNullValue }

    // Alternate rows are on by default, and a modified cell or an inserted row washes either row.
    private static func rowSurfaces(of theme: ThemeDefinition) throws -> [ThemeColor] {
        let background = try #require(theme.overrides[.gridBackground], "\(theme.id)")
        let stripe = try #require(theme.value(for: .gridAlternateRow).themedColor, "\(theme.id)")
        let rows = [background, stripe.composited(over: background)]
        let modified = try #require(theme.overrides[.gridModified], "\(theme.id)")
        let inserted = try #require(theme.overrides[.gridInserted], "\(theme.id)")
        return rows + [modified, inserted].flatMap { wash in rows.map { wash.composited(over: $0) } }
    }

    private static func lowestRatio(of color: ThemeColor, on surfaces: [ThemeColor]) -> Double {
        surfaces.map { color.contrastRatio(with: $0) }.min() ?? 0
    }

    @Test("Every bundled value color reaches 4.5:1 on both rows and on the modified and inserted washes over them")
    func bundledValueColorsOnEveryRowSurface() throws {
        let themes = try Self.bundledThemes()
        #expect(themes.count >= 14)
        #expect(Self.valueSlots.count == 9)

        for theme in themes {
            let surfaces = try Self.rowSurfaces(of: theme)
            for slot in Self.valueSlots {
                let color = try #require(theme.overrides[slot], "\(theme.id) sets no \(slot.rawValue)")
                let ratio = Self.lowestRatio(of: color, on: surfaces)
                #expect(ratio >= ThemeContrastNote.minimumRatio, "\(theme.id) \(slot.rawValue) \(color.hex): \(ratio)")
            }
            #expect(ThemeContrastNote.message(for: .values, in: theme) == nil, "\(theme.id)")
        }
    }

    @Test("No two value colors in a bundled theme are the same")
    func bundledValueColorsAreDistinct() throws {
        for theme in try Self.bundledThemes() {
            let colors = Self.valueSlots.compactMap { theme.overrides[$0] }
            let hexes = colors.map { $0.hex }
            #expect(colors.count == Self.valueSlots.count, "\(theme.id)")
            #expect(Set(colors).count == colors.count, "\(theme.id): \(hexes)")
        }
    }

    private static let valuesTheme = ThemeDefinition(
        id: "user.aaaa0004",
        name: "Ledger",
        author: "",
        appearance: .dark,
        overrides: [
            .gridBackground: ThemeColor(red: 0x28, green: 0x2A, blue: 0x36),
            .gridAlternateRow: ThemeColor(red: 0x21, green: 0x22, blue: 0x2C),
            .gridModified: ThemeColor(red: 0xFF, green: 0xB8, blue: 0x6C, alpha: 0x26),
            .gridInserted: ThemeColor(red: 0x50, green: 0xFA, blue: 0x7B, alpha: 0x26),
            .gridText: ThemeColor(red: 0xF8, green: 0xF8, blue: 0xF2),
            .gridBoolTrue: ThemeColor(red: 0x50, green: 0xFA, blue: 0x7B),
            .gridNumber: ThemeColor(red: 0xD6, green: 0xBC, blue: 0xFF),
        ]
    )

    @Test("The values note names the value color with the lowest contrast")
    func valuesNoteNamesTheLowest() throws {
        var theme = Self.valuesTheme
        #expect(ThemeContrastNote.message(for: .values, in: theme) == nil)

        theme.overrides[.gridJSON] = ThemeColor(red: 0x6B, green: 0x5A, blue: 0x30)
        theme.overrides[.gridBoolFalse] = ThemeColor(red: 0x80, green: 0x30, blue: 0x30)
        let surfaces = try Self.rowSurfaces(of: theme)
        let falseRatio = Self.lowestRatio(of: try #require(theme.overrides[.gridBoolFalse]), on: surfaces)
        let jsonRatio = Self.lowestRatio(of: try #require(theme.overrides[.gridJSON]), on: surfaces)
        #expect(falseRatio < jsonRatio)
        #expect(jsonRatio < ThemeContrastNote.minimumRatio)

        let lowest = try #require(ThemeContrastNote.lowest(for: .values, in: theme))
        #expect(lowest.slot == .gridBoolFalse)
        #expect(lowest.ratio == falseRatio)

        let formatted = falseRatio.formatted(.number.precision(.fractionLength(1)))
        #expect(
            ThemeContrastNote.message(for: .values, in: theme)
                == "Bool False contrast is \(formatted):1. Aim for at least 4.5:1."
        )
    }

    @Test(
        "The values note checks the alternate row and the modified and inserted washes over both rows",
        arguments: [
            (ThemeSlot.gridAlternateRow, ThemeColor(red: 0x5A, green: 0x5D, blue: 0x70)),
            (ThemeSlot.gridModified, ThemeColor(red: 0xFF, green: 0xB8, blue: 0x6C, alpha: 0x80)),
            (ThemeSlot.gridInserted, ThemeColor(red: 0x50, green: 0xFA, blue: 0x7B, alpha: 0x80)),
        ]
    )
    func valuesNoteChecksEveryRowSurface(surface: ThemeSlot, color: ThemeColor) throws {
        var theme = Self.valuesTheme
        theme.overrides[surface] = color
        let background = try #require(theme.overrides[.gridBackground])
        let number = try #require(theme.overrides[.gridNumber])
        let expected = Self.lowestRatio(of: number, on: try Self.rowSurfaces(of: theme))
        #expect(number.contrastRatio(with: background) >= ThemeContrastNote.minimumRatio)

        let lowest = try #require(ThemeContrastNote.lowest(for: .values, in: theme))
        #expect(lowest.slot == .gridNumber)
        #expect(lowest.ratio == expected)
        #expect(lowest.ratio < ThemeContrastNote.minimumRatio)
    }

    @Test("The values note skips NULL and the value colors that follow the grid text")
    func valuesNoteSkipsNullAndUnsetColors() {
        var theme = Self.valuesTheme
        theme.overrides[.gridNullValue] = ThemeColor(red: 0x30, green: 0x32, blue: 0x3E)
        #expect(ThemeContrastNote.message(for: .values, in: theme) == nil)

        theme.overrides[.gridText] = ThemeColor(red: 0x44, green: 0x47, blue: 0x5A)
        #expect(ThemeContrastNote.message(for: .values, in: theme) == nil)
        #expect(ThemeContrastNote.message(for: .dataGrid, in: theme)?.hasPrefix("Text contrast is ") == true)

        theme.overrides[.gridBoolTrue] = nil
        theme.overrides[.gridNumber] = nil
        #expect(ThemeContrastNote.lowest(for: .values, in: theme) == nil)
    }

    // MARK: - Selection

    // macOS's selections stand 18.1 (light) and 27.4 (dark) from the text background, its unfocused light one 7.4 (#4468).
    private static let selectionDifference = 15.0
    private static let inactiveSelectionDifference = 7.0

    // A fill past half of what a color stands above 1:1 buries comments, NULL and row numbers drawn on it. Whitespace marks
    // sit at 1.2 to 2.4:1 by design and only need to stay visible.
    private static let contrastKeptOnSelection = 0.5
    private static let invisiblesContrastKeptOnSelection = 1.0 / 3.0

    private static func contrastKept(by color: ThemeColor, on fill: ThemeColor, over background: ThemeColor) -> Double {
        let onBackground = color.composited(over: background).contrastRatio(with: background)
        guard onBackground > 1 else { return 1 }
        return (color.composited(over: fill).contrastRatio(with: fill) - 1) / (onBackground - 1)
    }

    private struct SelectionSurfaces {
        let editorBackground: ThemeColor
        let editorSelection: ThemeColor
        let rows: [ThemeColor]
        let selectedRows: [ThemeColor]
        let inactiveRows: [ThemeColor]

        init(_ theme: ThemeDefinition) throws {
            func color(_ slot: ThemeSlot) throws -> ThemeColor {
                try #require(theme.overrides[slot], "\(theme.id) sets no \(slot.rawValue)")
            }
            editorBackground = try color(.editorBackground)
            editorSelection = try color(.editorSelection).composited(over: editorBackground)
            let background = try color(.gridBackground)
            rows = [background, try color(.gridAlternateRow).composited(over: background)]
            let selection = try color(.gridSelection)
            let inactive = try color(.gridInactiveSelection)
            selectedRows = rows.map { selection.composited(over: $0) }
            inactiveRows = rows.map { inactive.composited(over: $0) }
        }
    }

    @Test("Every bundled selection stands apart from the background and the striped row it fills")
    func bundledSelectionsStandApart() throws {
        for theme in try Self.bundledThemes() {
            let surfaces = try SelectionSurfaces(theme)
            let editor = surfaces.editorSelection.perceptualDifference(from: surfaces.editorBackground)
            #expect(editor >= Self.selectionDifference, "\(theme.id) editor.selection: \(editor)")

            for (row, selected) in zip(surfaces.rows, surfaces.selectedRows) {
                let difference = selected.perceptualDifference(from: row)
                #expect(difference >= Self.selectionDifference, "\(theme.id) dataGrid.selection on \(row.hex): \(difference)")
            }
        }
    }

    @Test("Every bundled inactive grid selection stays visible on both rows and fainter than the focused one")
    func bundledInactiveSelectionsStayBelowFocused() throws {
        for theme in try Self.bundledThemes() {
            let surfaces = try SelectionSurfaces(theme)
            for index in surfaces.rows.indices {
                let row = surfaces.rows[index]
                let inactive = surfaces.inactiveRows[index].perceptualDifference(from: row)
                let focused = surfaces.selectedRows[index].perceptualDifference(from: row)
                #expect(inactive >= Self.inactiveSelectionDifference, "\(theme.id) on \(row.hex): \(inactive)")
                #expect(inactive < focused, "\(theme.id) on \(row.hex): inactive \(inactive), focused \(focused)")
            }
        }
    }

    // The SQL editor and an unfocused row keep each color on the selection; a focused row draws all of it in selectionText.
    @Test("Every color drawn on a bundled selection stays readable")
    func bundledSelectedColorsStayReadable() throws {
        for theme in try Self.bundledThemes() {
            let surfaces = try SelectionSurfaces(theme)
            let editorColors = ([.editorText] + ThemeSlotSection.syntax.slots).compactMap { theme.overrides[$0] }
            let gridColors = ([.gridText, .gridNullValue, .gridRowNumber] + ThemeSlotSection.values.slots)
                .compactMap { theme.overrides[$0] }
            let selectionText = try #require(theme.overrides[.gridSelectionText], "\(theme.id)")
            #expect(editorColors.count >= 6 && gridColors.count >= 12, "\(theme.id)")

            for color in editorColors {
                let kept = Self.contrastKept(by: color, on: surfaces.editorSelection, over: surfaces.editorBackground)
                #expect(kept >= Self.contrastKeptOnSelection, "\(theme.id) \(color.hex) on editor.selection: \(kept)")
            }
            let invisibles = try #require(theme.overrides[.editorInvisibles], "\(theme.id)")
            let invisiblesKept = Self.contrastKept(by: invisibles, on: surfaces.editorSelection, over: surfaces.editorBackground)
            #expect(invisiblesKept >= Self.invisiblesContrastKeptOnSelection, "\(theme.id) editor.invisibles: \(invisiblesKept)")
            for (row, inactive) in zip(surfaces.rows, surfaces.inactiveRows) {
                for color in gridColors {
                    let kept = Self.contrastKept(by: color, on: inactive, over: row)
                    #expect(kept >= Self.contrastKeptOnSelection, "\(theme.id) \(color.hex) on \(inactive.hex): \(kept)")
                }
            }
            for selected in surfaces.selectedRows {
                let ratio = selectionText.contrastRatio(with: selected)
                #expect(ratio >= ThemeContrastNote.minimumRatio, "\(theme.id) selectionText on \(selected.hex): \(ratio)")
            }
        }
    }

    @Test(
        "The perceptual difference matches the CIEDE2000 reference pairs",
        arguments: [
            (CIELab(lightness: 50, aStar: 2.6772, bStar: -79.7751), CIELab(lightness: 50, aStar: 0, bStar: -82.7485), 2.0425),
            (CIELab(lightness: 50, aStar: 0, bStar: 0), CIELab(lightness: 50, aStar: -1, bStar: 2), 2.3669),
            (CIELab(lightness: 50, aStar: 2.49, bStar: -0.001), CIELab(lightness: 50, aStar: -2.49, bStar: 0.0009), 7.1792),
            (CIELab(lightness: 50, aStar: 2.5, bStar: 0), CIELab(lightness: 73, aStar: 25, bStar: -18), 27.1492),
            (CIELab(lightness: 50, aStar: 2.5, bStar: 0), CIELab(lightness: 56, aStar: -27, bStar: -3), 31.9030),
            (CIELab(lightness: 60.2574, aStar: -34.0099, bStar: 36.2677), CIELab(lightness: 60.4626, aStar: -34.1751, bStar: 39.4387), 1.2644),
            (CIELab(lightness: 2.0776, aStar: 0.0795, bStar: -1.1350), CIELab(lightness: 0.9033, aStar: -0.0636, bStar: -0.5514), 0.9082),
        ]
    )
    func perceptualDifferenceMatchesReference(first: CIELab, second: CIELab, expected: Double) {
        #expect(abs(first.difference(from: second) - expected) < 0.0001)
        #expect(abs(second.difference(from: first) - expected) < 0.0001)
    }
}
