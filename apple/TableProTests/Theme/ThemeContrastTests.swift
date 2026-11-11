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

    @Test("Every bundled theme sets each value color at 4.5:1 or more on its grid background")
    func bundledValueColorsOnGridBackground() throws {
        let themes = try Self.bundledThemes()
        #expect(themes.count >= 14)
        #expect(Self.valueSlots.count == 9)

        for theme in themes {
            let background = try #require(theme.overrides[.gridBackground], "\(theme.id)")
            for slot in Self.valueSlots {
                let color = try #require(theme.overrides[slot], "\(theme.id) sets no \(slot.rawValue)")
                let ratio = color.contrastRatio(with: background)
                #expect(ratio >= ThemeContrastNote.minimumRatio, "\(theme.id) \(slot.rawValue) \(color.hex): \(ratio)")
            }
            #expect(ThemeContrastNote.message(for: .values, in: theme) == nil, "\(theme.id)")
        }
    }

    private static let valuesTheme = ThemeDefinition(
        id: "user.aaaa0004",
        name: "Ledger",
        author: "",
        appearance: .dark,
        overrides: [
            .gridBackground: ThemeColor(red: 0x28, green: 0x2A, blue: 0x36),
            .gridText: ThemeColor(red: 0xF8, green: 0xF8, blue: 0xF2),
            .gridBoolTrue: ThemeColor(red: 0x50, green: 0xFA, blue: 0x7B),
            .gridNumber: ThemeColor(red: 0xBD, green: 0x93, blue: 0xF9),
        ]
    )

    @Test("The values note names the value color with the lowest contrast")
    func valuesNoteNamesTheLowest() throws {
        var theme = Self.valuesTheme
        #expect(ThemeContrastNote.message(for: .values, in: theme) == nil)

        theme.overrides[.gridJSON] = ThemeColor(red: 0x6B, green: 0x5A, blue: 0x30)
        theme.overrides[.gridBoolFalse] = ThemeColor(red: 0x80, green: 0x30, blue: 0x30)
        let background = try #require(theme.overrides[.gridBackground])
        let falseRatio = try #require(theme.overrides[.gridBoolFalse]).contrastRatio(with: background)
        let jsonRatio = try #require(theme.overrides[.gridJSON]).contrastRatio(with: background)
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
}
