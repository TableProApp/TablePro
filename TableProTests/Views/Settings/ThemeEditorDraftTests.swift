import AppKit
@testable import TablePro
import Testing

@MainActor
struct ThemeEditorDraftTests {
    private func midnight() throws -> ThemeDefinition {
        var theme = BuiltInThemes.dark
        theme.id = "user.aaaa0002"
        theme.name = "Midnight"
        theme.overrides[.editorBackground] = try ThemeColor(validating: "#282A36")
        return theme
    }

    @Test("Setting a color overrides the slot, and Use Default removes the override")
    func setThenReset() throws {
        var draft = try ThemeEditorDraft(theme: midnight())
        let pink = try ThemeColor(validating: "#FF79C6")

        let set = draft.setColor(pink, for: .editorText)
        #expect(set)
        #expect(draft.theme.overrides[.editorText] == pink)

        let reset = draft.reset(.editorText)
        #expect(reset)
        #expect(!draft.theme.isOverridden(.editorText))

        let resetAgain = draft.reset(.editorText)
        #expect(!resetAgain)
    }

    @Test("Setting the value a slot already holds is not an edit")
    func sameOverrideIsNotAnEdit() throws {
        var draft = try ThemeEditorDraft(theme: midnight())
        let same = try ThemeColor(validating: "#282A36")

        let changed = draft.setColor(same, for: .editorBackground)
        #expect(!changed)
    }

    /// A well hands back the color it shows. Storing that echo would freeze a system color into
    /// the file, and the slot would stop following Accent and Increase Contrast.
    @Test("The system color a well shows for an unset slot is not stored when echoed back")
    func echoOfTheSystemColorIsIgnored() throws {
        var draft = try ThemeEditorDraft(theme: midnight())
        let shown = ThemeColor(draft.displayColor(for: .gridBackground))

        let changed = draft.setColor(shown, for: .gridBackground)
        #expect(!changed)
        #expect(!draft.theme.isOverridden(.gridBackground))
    }

    @Test("An unset slot shows its system color in the theme's appearance, not the app's")
    func unsetSlotResolvesInTheThemeAppearance() throws {
        let draft = try ThemeEditorDraft(theme: midnight())
        let dark = try #require(NSAppearance(named: .darkAqua))
        var expected = NSColor.controlBackgroundColor
        dark.performAsCurrentDrawingAppearance {
            expected = NSColor.controlBackgroundColor.usingColorSpace(.sRGB) ?? expected
        }

        let shown = ThemeColor(draft.displayColor(for: .gridBackground))
        #expect(shown == ThemeColor(expected))
    }

    @Test("An overridden slot shows its override")
    func overriddenSlotShowsItsOverride() throws {
        let draft = try ThemeEditorDraft(theme: midnight())
        let shown = ThemeColor(draft.displayColor(for: .editorBackground))
        #expect(shown.hex == "#282A36")
    }

    @Test("A rename to the current name is not an edit")
    func renameReportsChange() throws {
        var draft = try ThemeEditorDraft(theme: midnight())

        let unchanged = draft.rename(to: "Midnight")
        #expect(!unchanged)

        let renamed = draft.rename(to: "Night Owl")
        #expect(renamed)
        #expect(draft.theme.name == "Night Owl")
    }
}
