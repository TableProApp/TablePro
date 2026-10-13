//
//  NativeDefaultsTests.swift
//  TableProTests
//
//  Default Light and Default Dark have to render exactly like an unthemed NSTextView and
//  NSTableView, following Accent, Highlight and Increase Contrast. That holds only while every
//  slot they leave out hands back the system color object itself: a hex default, or a copy
//  flattened under a hand-built appearance, freezes it.
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct NativeDefaultsTests {
    private static let surroundSlots = ThemeSlot.allCases.filter { $0.group != .syntax }

    private static func hex(_ color: NSColor) -> String {
        HexColor.string(from: color)
    }

    private static func theme(
        _ appearance: ThemeAppearance,
        overriding overrides: [ThemeSlot: String]
    ) throws -> ThemeDefinition {
        var colors: [ThemeSlot: ThemeColor] = [:]
        for (slot, value) in overrides {
            colors[slot] = try ThemeColor(validating: value)
        }
        return ThemeDefinition(id: "user.native", name: "Native", author: "", appearance: appearance, overrides: colors)
    }

    private static func bundledTheme(_ id: String) throws -> ThemeDefinition {
        let url = try ThemeSourceScan.repositoryRoot().appendingPathComponent("TablePro/Resources/Themes/\(id).json")
        return try ThemeDocument(data: try Data(contentsOf: url)).definition()
    }

    // MARK: - Definitions

    @Test("The default themes hand back the native color object for every non-syntax slot")
    func defaultsReturnTheNativeObject() {
        for theme in BuiltInThemes.all {
            for slot in Self.surroundSlots {
                #expect(!theme.isOverridden(slot), "\(theme.id) overrides \(slot.rawValue)")
                #expect(theme.color(for: slot) === slot.nativeColor, "\(theme.id) replaces native \(slot.rawValue)")
            }
        }
    }

    @Test("Each surface's native color is the one AppKit draws there")
    func nativeColorsAreAppKitDefaults() {
        for theme in BuiltInThemes.all {
            #expect(theme.color(for: .windowBackdrop) === NSColor.windowBackgroundColor)
            #expect(theme.color(for: .editorBackground) === NSColor.textBackgroundColor)
            #expect(theme.color(for: .editorText) === NSColor.textColor)
            #expect(theme.color(for: .editorSelection) === NSColor.selectedTextBackgroundColor)
            #expect(theme.color(for: .gridBackground) === NSColor.controlBackgroundColor)
            #expect(theme.color(for: .gridLine) === NSColor.separatorColor)
            #expect(theme.color(for: .gridHeaderText) === NSColor.headerTextColor)
            #expect(theme.color(for: .gridSelection) === NSColor.selectedContentBackgroundColor)
            #expect(theme.color(for: .gridInactiveSelection) === NSColor.unemphasizedSelectedContentBackgroundColor)
            #expect(theme.color(for: .gridFocusBorder) === NSColor.keyboardFocusIndicatorColor)
        }
    }

    /// macOS 14 draws the caret in the Highlight color, not in the text color.
    @Test("The default caret is the system insertion point color")
    func caretIsTheSystemInsertionPoint() {
        guard #available(macOS 14.0, *) else { return }
        for theme in BuiltInThemes.all {
            #expect(theme.color(for: .editorCursor) === NSColor.textInsertionPointColor)
        }
    }

    @Test("Operator falls back to the editor text, native or overridden")
    func operatorFollowsEditorText() throws {
        for theme in BuiltInThemes.all {
            #expect(theme.color(for: .syntaxOperator) === NSColor.textColor)
        }

        let textOnly = try Self.theme(.dark, overriding: [.editorText: "#112233"])
        #expect(Self.hex(textOnly.color(for: .syntaxOperator)) == "#112233")

        let both = try Self.theme(.dark, overriding: [.editorText: "#112233", .syntaxOperator: "#445566"])
        #expect(Self.hex(both.color(for: .syntaxOperator)) == "#445566")
    }

    @Test("A theme that overrides only the background keeps every other surface native")
    func backgroundOnlyThemeKeepsNativeSelection() throws {
        let theme = try Self.theme(.dark, overriding: [.editorBackground: "#282A36"])

        #expect(Self.hex(theme.color(for: .editorBackground)) == "#282A36")
        #expect(theme.color(for: .editorSelection) === NSColor.selectedTextBackgroundColor)
        #expect(theme.color(for: .editorCursor) === ThemeSlot.editorCursor.nativeColor)
        #expect(theme.color(for: .gridSelection) === NSColor.selectedContentBackgroundColor)
        #expect(theme.color(for: .gridBackground) === NSColor.controlBackgroundColor)
    }

    /// Syntax has no system color, so a theme that leaves one out takes its own appearance's default.
    @Test("A syntax slot a theme leaves out takes the same-appearance default")
    func missingSyntaxTakesTheSameAppearanceDefault() throws {
        let dark = try Self.theme(.dark, overriding: [.editorBackground: "#282A36"])
        let light = try Self.theme(.light, overriding: [.editorBackground: "#FFFFF0"])

        #expect(Self.hex(dark.color(for: .syntaxKeyword)) == "#FC5FA3")
        #expect(Self.hex(light.color(for: .syntaxKeyword)) == "#9B2393")
        #expect(Self.hex(light.color(for: .syntaxString)) == "#C41A16")
    }

    // MARK: - Resolved theme

    @Test("ResolvedTheme keeps the system color object for every slot the theme leaves out")
    func resolvedThemeNeverFlattens() throws {
        for theme in BuiltInThemes.all {
            let resolved = ResolvedTheme(definition: theme)
            for slot in Self.surroundSlots {
                #expect(!resolved.isOverridden(slot))
                #expect(resolved[slot] === slot.nativeColor, "\(theme.id) flattens \(slot.rawValue)")
            }
        }

        let partial = ResolvedTheme(definition: try Self.theme(.dark, overriding: [.gridBackground: "#282A36"]))
        #expect(partial.isOverridden(.gridBackground))
        #expect(Self.hex(partial[.gridBackground]) == "#282A36")
        #expect(!partial.isOverridden(.gridSelection))
        #expect(partial[.gridSelection] === NSColor.selectedContentBackgroundColor)
    }

    @Test("cgColor resolves a system slot inside the appearance it is given")
    func cgColorResolvesInTheGivenAppearance() throws {
        let resolved = ResolvedTheme(definition: BuiltInThemes.light)
        var resolvedComponents: [NSAppearance.Name: [CGFloat]] = [:]

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var expected: [CGFloat] = []
            appearance.performAsCurrentDrawingAppearance {
                expected = NSColor.textBackgroundColor.cgColor.components ?? []
            }
            let actual = resolved.cgColor(.editorBackground, in: appearance).components ?? []

            #expect(!actual.isEmpty)
            #expect(actual == expected, "\(name.rawValue)")
            resolvedComponents[name] = actual
        }

        #expect(resolvedComponents[.aqua] != resolvedComponents[.darkAqua])
    }

    // MARK: - Palette

    @Test("The Default palette resolves to the native color in Aqua and Dark Aqua")
    func defaultPaletteResolvesNatively() throws {
        let palette = ThemePalette(revision: 910_001, source: ThemeSource())

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for slot in Self.surroundSlots {
                    #expect(
                        Self.hex(palette[slot]) == Self.hex(slot.nativeColor),
                        "\(slot.rawValue) in \(name.rawValue)"
                    )
                }
            }
        }
    }

    @Test("The palette takes each appearance's syntax from that appearance's default")
    func paletteSyntaxFollowsTheAppearance() throws {
        let palette = ThemePalette(revision: 910_002, source: ThemeSource())
        let aqua = try #require(NSAppearance(named: .aqua))
        let darkAqua = try #require(NSAppearance(named: .darkAqua))

        aqua.performAsCurrentDrawingAppearance {
            #expect(Self.hex(palette[.syntaxKeyword]) == "#9B2393")
        }
        darkAqua.performAsCurrentDrawingAppearance {
            #expect(Self.hex(palette[.syntaxKeyword]) == "#FC5FA3")
        }
    }

    @Test("Dracula colors its surfaces in Dark Aqua and leaves Aqua to the light default")
    func draculaPaletteResolvesItsBackground() throws {
        let dracula = try Self.bundledTheme("tablepro.dracula")
        let source = ThemeSource()
        source.update(ThemePair(light: BuiltInThemes.light, dark: dracula))
        let palette = ThemePalette(revision: 910_003, source: source)
        let aqua = try #require(NSAppearance(named: .aqua))
        let darkAqua = try #require(NSAppearance(named: .darkAqua))

        darkAqua.performAsCurrentDrawingAppearance {
            #expect(Self.hex(palette[.editorBackground]) == "#282A36")
            #expect(Self.hex(palette[.gridBackground]) == "#282A36")
        }
        aqua.performAsCurrentDrawingAppearance {
            #expect(Self.hex(palette[.editorBackground]) == Self.hex(NSColor.textBackgroundColor))
            #expect(Self.hex(palette[.gridSelection]) == Self.hex(NSColor.selectedContentBackgroundColor))
        }
    }

    // MARK: - Window background

    @Test("Default Light and Default Dark leave the window background to the system")
    func defaultsLeaveTheWindowBackgroundUnset() {
        for theme in BuiltInThemes.all {
            #expect(!theme.isOverridden(.windowBackdrop), "\(theme.id)")
            #expect(theme.overrides[.windowBackdrop] == nil, "\(theme.id)")
        }
    }

    @Test("Dracula and Nord set the window background in Dark Aqua")
    func bundledThemesSetTheWindowBackground() throws {
        let expectations: [(id: String, hex: String)] = [("tablepro.dracula", "#282A36"), ("tablepro.nord", "#2E3440")]
        let darkAqua = try #require(NSAppearance(named: .darkAqua))

        for expectation in expectations {
            let theme = try Self.bundledTheme(expectation.id)
            #expect(theme.overrides[.windowBackdrop]?.hex == expectation.hex, "\(expectation.id)")
            darkAqua.performAsCurrentDrawingAppearance {
                #expect(Self.hex(theme.color(for: .windowBackdrop, in: darkAqua)) == expectation.hex, "\(expectation.id)")
            }
        }
    }

    // MARK: - Fallback colors

    /// The fallback is not the slot's own native color, so a match proves the fallback is what draws.
    @Test("Under the default pair the palette fallback draws the fallback in every appearance")
    func paletteFallbackUnderTheDefaultPair() throws {
        let palette = ThemePalette(revision: 910_004, source: ThemeSource())

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for slot in Self.surroundSlots {
                    #expect(
                        Self.hex(palette.color(slot, otherwise: .systemRed)) == Self.hex(NSColor.systemRed),
                        "\(slot.rawValue) in \(name.rawValue)"
                    )
                }
            }
        }
    }

    @Test("The palette fallback gives way to the theme only in the appearance whose theme sets the slot")
    func paletteFallbackUnderAnOverride() throws {
        let source = ThemeSource()
        source.update(ThemePair(light: BuiltInThemes.light, dark: try Self.bundledTheme("tablepro.dracula")))
        let palette = ThemePalette(revision: 910_005, source: source)
        let aqua = try #require(NSAppearance(named: .aqua))
        let darkAqua = try #require(NSAppearance(named: .darkAqua))

        darkAqua.performAsCurrentDrawingAppearance {
            #expect(Self.hex(palette.color(.windowBackdrop, otherwise: .systemRed)) == "#282A36")
            #expect(Self.hex(palette.color(.editorBackground, otherwise: .systemRed)) == "#282A36")
        }
        aqua.performAsCurrentDrawingAppearance {
            #expect(Self.hex(palette.color(.windowBackdrop, otherwise: .systemRed)) == Self.hex(NSColor.systemRed))
        }
    }

    /// `NSAppearance(named:)` hands back plain Dark Aqua for the high-contrast names; only the system
    /// setting produces one, so the rule is held here rather than through a drawing appearance.
    @Test("Under Increase Contrast the window background yields to the system and content slots keep the theme")
    func windowBackgroundYieldsToIncreasedContrast() throws {
        let dracula = try Self.bundledTheme("tablepro.dracula")
        let darkAqua = try #require(NSAppearance(named: .darkAqua))

        #expect(!dracula.isOverridden(.windowBackdrop, highContrast: true))
        #expect(dracula.isOverridden(.windowBackdrop, highContrast: false))
        #expect(dracula.isOverridden(.editorBackground, highContrast: true))
        #expect(dracula.isOverridden(.gridBackground, highContrast: true))
        #expect(dracula.isOverridden(.windowBackdrop, in: darkAqua))
    }

    @Test("ResolvedTheme hands back the fallback object itself for a slot the theme leaves out")
    func resolvedFallbackIsTheObject() throws {
        for theme in BuiltInThemes.all {
            let resolved = ResolvedTheme(definition: theme)
            for slot in Self.surroundSlots {
                #expect(resolved.color(slot, otherwise: .systemRed) === NSColor.systemRed, "\(slot.rawValue)")
            }
        }

        let dracula = ResolvedTheme(definition: try Self.bundledTheme("tablepro.dracula"))
        let darkAqua = try #require(NSAppearance(named: .darkAqua))
        darkAqua.performAsCurrentDrawingAppearance {
            #expect(Self.hex(dracula.color(.windowBackdrop, otherwise: .systemRed)) == "#282A36")
            #expect(Self.hex(dracula.color(.gridBackground, otherwise: .systemRed)) == "#282A36")
        }
    }

    @Test("cgColor with a fallback resolves the fallback inside the given appearance")
    func cgColorFallbackResolvesInTheGivenAppearance() throws {
        let resolved = ResolvedTheme(definition: BuiltInThemes.light)
        var components: [NSAppearance.Name: [CGFloat]] = [:]

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var expected: [CGFloat] = []
            appearance.performAsCurrentDrawingAppearance {
                expected = NSColor.underPageBackgroundColor.cgColor.components ?? []
            }
            let actual = resolved.cgColor(.windowBackdrop, otherwise: .underPageBackgroundColor, in: appearance).components ?? []

            #expect(!actual.isEmpty)
            #expect(actual == expected, "\(name.rawValue)")
            components[name] = actual
        }

        #expect(components[.aqua] != components[.darkAqua])
    }

    // MARK: - SwiftUI surfaces

    private static func centerColor(of view: some View) throws -> NSColor {
        try ThemeTestFixture.color(of: view, at: CGPoint(x: 0.5, y: 0.5), colorScheme: .dark)
    }

    @Test("themeBackground draws the native style as passed until the active theme sets the slot")
    func themeBackgroundNativePath() throws {
        let swatch = Color.clear
            .frame(width: 24, height: 24)
            .themeBackground(.windowBackdrop, native: Color(nsColor: .systemRed))

        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            #expect(ThemeShapeStyle.override(.windowBackdrop, contrast: .standard) == nil)
            #expect(ThemeShapeStyle.override(.editorBackground, contrast: .standard) == nil)
            let drawn = try Self.centerColor(of: swatch)
            let native = try ThemeTestFixture.filled(.systemRed, colorScheme: .dark)
            #expect(ThemeTestFixture.matches(drawn, native), "drew \(drawn), native \(native)")
        }

        let dracula = ThemePair(light: BuiltInThemes.light, dark: try Self.bundledTheme("tablepro.dracula"))
        try ThemeTestFixture.adopting(dracula, appearance: .dark) {
            #expect(ThemeShapeStyle.override(.windowBackdrop, contrast: .standard) != nil)
            #expect(ThemeShapeStyle.override(.windowBackdrop, contrast: .increased) == nil)
            #expect(ThemeShapeStyle.override(.editorBackground, contrast: .increased) != nil)
            let drawn = try Self.centerColor(of: swatch)
            let themed = try ThemeTestFixture.filled(hex: "#282A36", colorScheme: .dark)
            let native = try ThemeTestFixture.filled(.systemRed, colorScheme: .dark)
            #expect(ThemeTestFixture.matches(drawn, themed), "drew \(drawn), theme \(themed)")
            #expect(!ThemeTestFixture.matches(drawn, native))
        }
    }
}
