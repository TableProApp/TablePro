//
//  EditorThemeBridgeTests.swift
//  TableProTests
//
//  The colours the app's theme engine hands the editor. Everything about how the editor then paints
//  them lives with the editor, in TableProEditorKitTests.
//

import AppKit
@testable import TablePro
import TableProEditorKit
import TableProTheme
import Testing

@MainActor
struct EditorThemeBridgeTests {
    @Test("Default Light hands the editor the system's own color objects around the text")
    func defaultLightSurroundIsSystem() {
        expectSystemSurround(makeTheme(.builtIn, appearance: .light))
    }

    @Test("Default Dark hands the editor the system's own color objects around the text")
    func defaultDarkSurroundIsSystem() {
        expectSystemSurround(makeTheme(.builtIn, appearance: .dark))
    }

    @Test("Default Light syntax is Xcode's Default (Light)")
    func defaultLightSyntaxIsXcode() {
        let theme = makeTheme(.builtIn, appearance: .light)

        #expect(hex(theme.keywords) == "#9B2393")
        #expect(hex(theme.values) == "#9B2393")
        #expect(hex(theme.attributes) == "#9B2393")
        #expect(hex(theme.strings) == "#C41A16")
        #expect(hex(theme.numbers) == "#1C00CF")
        #expect(hex(theme.comments) == "#5D6C79")
        #expect(hex(theme.functions) == "#6C36A9")
        #expect(hex(theme.types) == "#3900A0")
        #expect(theme.keywords.bold)
    }

    @Test("Default Dark syntax is Xcode's Default (Dark)")
    func defaultDarkSyntaxIsXcode() {
        let theme = makeTheme(.builtIn, appearance: .dark)

        #expect(hex(theme.keywords) == "#FC5FA3")
        #expect(hex(theme.values) == "#FC5FA3")
        #expect(hex(theme.attributes) == "#FC5FA3")
        #expect(hex(theme.strings) == "#FC6A5D")
        #expect(hex(theme.numbers) == "#D0BF69")
        #expect(hex(theme.comments) == "#6C7986")
        #expect(hex(theme.functions) == "#A167E6")
        #expect(hex(theme.types) == "#D0A8FF")
    }

    @Test("The caret stays the system's unless a theme sets a cursor color")
    func caretIsNilUnlessOverridden() throws {
        #expect(makeTheme(.builtIn, appearance: .light).insertionPoint == nil)

        var custom = BuiltInThemes.light
        custom.id = "test.editor-cursor"
        custom.overrides[.editorCursor] = try ThemeColor(validating: "#FF00FF")
        let theme = makeTheme(ThemePair(light: custom, dark: BuiltInThemes.dark), appearance: .light)

        let caret = try #require(theme.insertionPoint)
        #expect(HexColor.string(from: caret) == "#FF00FF")
    }

    @Test("A theme overrides only the slots it declares")
    func overrideReplacesOnlyItsSlot() throws {
        var custom = BuiltInThemes.dark
        custom.id = "test.editor-background"
        custom.overrides[.editorBackground] = try ThemeColor(validating: "#282A36")
        let theme = makeTheme(ThemePair(light: BuiltInThemes.light, dark: custom), appearance: .dark)

        #expect(HexColor.string(from: theme.background) == "#282A36")
        #expect(theme.selection == .selectedTextBackgroundColor)
        #expect(theme.text.color == .textColor)
    }

    /// Accent, Highlight and Increase Contrast all send `themeChanged`, and every editor rebuilds its
    /// theme on it. Only an equal theme keeps that from restyling the whole document each time.
    @Test("Building the theme twice gives an equal theme")
    func rebuildingIsEqual() {
        for appearance in [ThemeAppearance.light, .dark] {
            let first = makeTheme(.builtIn, appearance: appearance)
            let second = makeTheme(.builtIn, appearance: appearance)
            #expect(first == second, "\(appearance)")
        }
    }

    /// The grammar tags aliases, parameters and properties as variables. They are names the user
    /// wrote, so they draw in the editor text rather than in the NULL color.
    @Test("Variables take the editor text, constants keep the NULL slot", arguments: [ThemeAppearance.light, .dark])
    func variablesTakeTheEditorText(appearance: ThemeAppearance) throws {
        let defaults = makeTheme(.builtIn, appearance: appearance)
        #expect(defaults.variables == defaults.text)
        #expect(defaults.variables.color === NSColor.textColor)
        #expect(!defaults.variables.bold)

        var custom = BuiltInThemes.default(for: appearance)
        custom.overrides[.editorText] = try ThemeColor(validating: "#112233")
        custom.overrides[.syntaxNull] = try ThemeColor(validating: "#AA5500")
        let pair = appearance == .light
            ? ThemePair(light: custom, dark: BuiltInThemes.dark)
            : ThemePair(light: BuiltInThemes.light, dark: custom)
        let themed = makeTheme(pair, appearance: appearance)

        #expect(hex(themed.variables) == "#112233")
        #expect(hex(themed.values) == "#AA5500")
        #expect(hex(themed.attributes) == "#AA5500")
    }

    @Test("The factory builds the same theme the engine hands the editor")
    func factoryMatchesTheEngine() {
        let settings = AppSettingsManager.shared.editor
        let made = EditorThemeFactory.make(
            resolved: ThemeEngine.shared.resolved,
            highlightsCurrentLine: settings.highlightCurrentLine,
            highlightsCurrentStatement: settings.highlightCurrentStatement
        )
        #expect(made == ThemeEngine.shared.makeEditorTheme())

        let plain = EditorThemeFactory.make(
            resolved: ResolvedTheme(definition: BuiltInThemes.light),
            highlightsCurrentLine: false,
            highlightsCurrentStatement: false
        )
        #expect(plain.lineHighlight == .clear)
        #expect(plain.statementHighlight == .clear)
    }

    @Test("The theme's operator and function colours reach the editor")
    func themeCarriesOperatorAndFunctionColors() {
        let theme = ThemeEngine.shared.makeEditorTheme()
        let resolved = ThemeEngine.shared.resolved

        #expect(theme.operators.color == resolved[.syntaxOperator])
        #expect(theme.functions.color == resolved[.syntaxFunction])
    }

    private func expectSystemSurround(_ theme: EditorTheme) {
        let settings = AppSettingsManager.shared.editor

        #expect(theme.background == .textBackgroundColor)
        #expect(theme.background.type == .catalog)
        #expect(theme.text.color == .textColor)
        #expect(theme.operators.color == .textColor)
        #expect(theme.selection == .selectedTextBackgroundColor)
        #expect(theme.lineNumber == .secondaryLabelColor)
        #expect(theme.invisibles.color == .tertiaryLabelColor)
        #expect(theme.lineHighlight == (settings.highlightCurrentLine ? NativeThemeColors.currentLine : .clear))
        #expect(theme.statementHighlight == (settings.highlightCurrentStatement ? .quinaryLabel : .clear))
        #expect(theme.insertionPoint == nil)
    }

    private func makeTheme(_ pair: ThemePair, appearance: ThemeAppearance) -> EditorTheme {
        let engine = ThemeEngine.shared
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }
        engine.adopt(ThemeSelection(pair: pair, effectiveAppearance: appearance))
        return engine.makeEditorTheme()
    }

    private func hex(_ attribute: EditorTheme.Attribute) -> String {
        HexColor.string(from: attribute.color)
    }
}
