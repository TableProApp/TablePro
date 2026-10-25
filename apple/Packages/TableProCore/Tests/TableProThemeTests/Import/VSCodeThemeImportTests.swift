import Foundation
import TableProTheme
import Testing

struct VSCodeThemeImportTests {
    private static func theme(_ json: String, named fileName: String = "theme.json") throws -> ThemeDefinition {
        let folder = try ThemeImportFolder()
        defer { folder.remove() }
        try folder.write(json, as: fileName)
        return try folder.importTheme(fileName)
    }

    private static func refusal(_ json: String) throws -> ThemeLoadError? {
        let folder = try ThemeImportFolder()
        defer { folder.remove() }
        try folder.write(json, as: "theme.json")
        return folder.refusal(importing: "theme.json")
    }

    @Test("A VS Code theme is recognized by its keys or its $schema, and gets a new user id every time")
    func routingAndFreshId() throws {
        let folder = try ThemeImportFolder()
        defer { folder.remove() }
        try folder.write(##"{"$schema": "vscode://schemas/color-theme", "colors": {"editor.background": "#1E1E1E"}}"##, as: "a.json")

        let first = try folder.importTheme("a.json")
        let second = try folder.importTheme("a.json")

        #expect(first.id != second.id)
        #expect(first.id.hasPrefix(ThemeDefinition.userPrefix))
        #expect(ThemeIdentifier.isValid(first.id))
        #expect(first.isEditable)
        for key in ["colors", "tokenColors", "include", "settings"] {
            #expect(try Self.refusal(##"{"\##(key)": null}"##) != .notATheme, "\(key)")
        }
        #expect(try Self.refusal(##"{"$schema": "vscode://schemas/color-theme"}"##) == .noUsableColors)
        #expect(try Self.refusal(##"{"$schema": "https://json-schema.org/draft-07/schema", "name": "x"}"##) == .notATheme)
    }

    @Test("An integer schema routes to the TablePro format, whose strict decoder refuses comments")
    func integerSchemaRoutesToTablePro() throws {
        let error = try Self.refusal(
            """
            {"schema": 3, // a comment
             "id": "user.a", "name": "x", "appearance": "dark", "colors": {"editor.background": "#000000"}}
            """
        )

        guard case .malformedJSON = error else {
            Issue.record("expected the TablePro decoder's malformedJSON, got \(String(describing: error))")
            return
        }
    }

    @Test("A theme with nothing TablePro reads is refused")
    func nothingUsable() throws {
        #expect(try Self.refusal(##"{"name": "x", "colors": {}}"##) == .noUsableColors)
        #expect(try Self.refusal(##"{"colors": {"activityBar.background": "#123456"}}"##) == .noUsableColors)
        #expect(
            try Self.refusal(##"{"tokenColors": [{"scope": "markup.heading", "settings": {"foreground": "#FF0000"}}]}"##)
                == .noUsableColors
        )
    }

    @Test("Appearance comes from type, then the editor background's luminance, then dark")
    func appearanceInference() throws {
        let darkBackground = ##""colors": {"editor.background": "#1E1E1E"}"##
        let lightBackground = ##""colors": {"editor.background": "#FAFAFA"}"##
        let tokens = ##""tokenColors": [{"scope": "keyword", "settings": {"foreground": "#AA00AA"}}]"##

        #expect(try Self.theme(##"{"type": "light", \##(darkBackground)}"##).appearance == .light)
        #expect(try Self.theme(##"{"type": "VS", \##(darkBackground)}"##).appearance == .light)
        #expect(try Self.theme(##"{"type": "hcLight", \##(darkBackground)}"##).appearance == .light)
        #expect(try Self.theme(##"{"type": "hc-light", \##(darkBackground)}"##).appearance == .light)
        #expect(try Self.theme(##"{"type": "dark", \##(lightBackground)}"##).appearance == .dark)
        #expect(try Self.theme(##"{"type": "vs-dark", \##(lightBackground)}"##).appearance == .dark)
        #expect(try Self.theme(##"{"type": "hc-black", \##(lightBackground)}"##).appearance == .dark)
        #expect(try Self.theme(##"{"type": "hcDark", \##(lightBackground)}"##).appearance == .dark)
        #expect(try Self.theme(##"{"type": "sepia", \##(lightBackground)}"##).appearance == .light)
        #expect(try Self.theme(##"{\##(lightBackground)}"##).appearance == .light)
        #expect(try Self.theme(##"{\##(darkBackground)}"##).appearance == .dark)
        #expect(try Self.theme(##"{\##(tokens)}"##).appearance == .dark)
    }

    @Test("The name is the file's own, else the file name without .json and -color-theme")
    func names() throws {
        let colors = ##""colors": {"editor.background": "#1E1E1E"}"##

        #expect(try Self.theme(##"{"name": "  Night Owl  ", \##(colors)}"##).name == "Night Owl")
        #expect(try Self.theme(##"{\##(colors)}"##, named: "dracula-color-theme.json").name == "dracula")
        #expect(try Self.theme(##"{\##(colors)}"##, named: "Solarized Dark-Color-Theme.JSON").name == "Solarized Dark")
        #expect(try Self.theme(##"{"name": 7, \##(colors)}"##, named: "Plain.json").name == "Plain")
        #expect(try Self.theme(##"{"name": "   ", \##(colors)}"##, named: "Blank.json").name == "Blank")
        #expect(try Self.theme(##"{"name": "Two\nLines\t Here", \##(colors)}"##).name == "Two Lines Here")

        let long = try Self.theme(##"{"name": "\##(String(repeating: "x", count: 150))", \##(colors)}"##)
        #expect(long.name == String(repeating: "x", count: ThemeFileFormat.maximumTextLength))
    }

    @Test("The author is kept when it is a string")
    func author() throws {
        let colors = ##""colors": {"editor.background": "#1E1E1E"}"##

        #expect(try Self.theme(##"{"author": "Zeno Rocha", \##(colors)}"##).author == "Zeno Rocha")
        #expect(try Self.theme(##"{"author": {"name": "x"}, \##(colors)}"##).author.isEmpty)
        #expect(try Self.theme(##"{\##(colors)}"##).author.isEmpty)
    }

    @Test("A syntax slot no rule colors takes editor.foreground, as VS Code paints it, and NULL takes the keyword")
    func syntaxFallsBackToEditorForeground() throws {
        let theme = try Self.theme(
            """
            {"colors": {"editor.background": "#1E1E1E", "editor.foreground": "#ABCDEF"},
             "tokenColors": [{"scope": "keyword", "settings": {"foreground": "#FF00FF"}}]}
            """
        )

        #expect(theme.hex(.syntaxKeyword) == "#FF00FF")
        #expect(theme.hex(.syntaxNull) == "#FF00FF")
        #expect(theme.hex(.syntaxOperator) == "#FF00FF")
        for slot in [ThemeSlot.syntaxString, .syntaxNumber, .syntaxComment, .syntaxFunction, .syntaxType] {
            #expect(theme.hex(slot) == "#ABCDEF", "\(slot)")
        }
    }

    @Test("Without editor.foreground, syntax takes VS Code's default text color for the theme's type")
    func syntaxFallsBackToTheRegistryDefault() throws {
        let dark = try Self.theme(##"{"colors": {"editor.background": "#101010"}}"##)
        let light = try Self.theme(##"{"type": "light", "colors": {"editor.background": "#FFFFFF"}}"##)
        let highContrast = try Self.theme(##"{"type": "hc-black", "colors": {"editor.background": "#000000"}}"##)

        #expect(dark.hex(.syntaxKeyword) == "#BBBBBB")
        #expect(light.hex(.syntaxKeyword) == "#333333")
        #expect(highContrast.hex(.syntaxKeyword) == "#FFFFFF")
        #expect(dark.hex(.editorText) == nil)
    }

    @Test("The four fills nothing themed sits under are flattened; washes keep their alpha")
    func opaqueSlotsAreFlattened() throws {
        let theme = try Self.theme(
            """
            {"type": "dark", "colors": {
              "editor.background": "#20406080",
              "editorPane.background": "#FFFFFF33",
              "keybindingTable.headerBackground": "#FFFFFF1A",
              "editor.selectionBackground": "#3050A080",
              "keybindingTable.rowsBackground": "#FFFFFF0A"
            }}
            """
        )
        let editor = ThemeColor(red: 0x20, green: 0x40, blue: 0x60, alpha: 0x80)
            .composited(over: ThemeColor(red: 0x1E, green: 0x1E, blue: 0x1E))

        #expect(theme.overrides[.editorBackground] == editor)
        #expect(theme.overrides[.gridBackground] == editor)
        #expect(theme.overrides[.windowBackdrop] == ThemeColor(red: 255, green: 255, blue: 255, alpha: 0x33).composited(over: editor))
        #expect(theme.overrides[.gridHeaderBackground] == ThemeColor(red: 255, green: 255, blue: 255, alpha: 0x1A).composited(over: editor))
        for slot in ThemeSlot.allCases where slot.requiresOpaque {
            #expect(theme.overrides[slot]?.isOpaque == true, "\(slot)")
        }
        #expect(theme.hex(.editorSelection) == "#3050A080")
        #expect(theme.hex(.gridAlternateRow) == "#FFFFFF0A")
    }

    @Test("A slot the fallback rules already derive from what the theme sets stays unset")
    func derivableSlotsStayUnset() throws {
        let theme = try Self.theme(
            """
            {"colors": {
              "editor.background": "#202020",
              "editor.foreground": "#E0E0E0"
            }, "tokenColors": [{"scope": "constant.language.boolean", "settings": {"foreground": "#E0E0E0"}}]}
            """
        )

        #expect(theme.hex(.gridBoolTrue) == nil)
        #expect(theme.hex(.gridBoolFalse) == nil)
        #expect(theme.value(for: .gridBoolTrue) == .themed(ThemeColor(red: 0xE0, green: 0xE0, blue: 0xE0)))
    }

    @Test("A VS Code theme's table header, list selection and focus colors import as set, even where they match the grid")
    func selectionAndHeaderColorsImport() throws {
        let theme = try Self.theme(
            """
            {"colors": {"editor.background": "#202020", "editor.foreground": "#E0E0E0",
              "list.activeSelectionBackground": "#0050A0", "list.activeSelectionForeground": "#FFFFFF",
              "list.inactiveSelectionBackground": "#00305080", "list.focusOutline": "#0080FF",
              "focusBorder": "#3366FF", "keybindingTable.headerBackground": "#202020", "foreground": "#E0E0E0"}}
            """
        )

        #expect(theme.hex(.gridHeaderBackground) == "#202020")
        #expect(theme.hex(.gridHeaderText) == "#E0E0E0")
        #expect(theme.hex(.gridSelection) == "#0050A0")
        #expect(theme.hex(.gridSelectionText) == "#FFFFFF")
        #expect(theme.hex(.gridInactiveSelection) == "#00305080")
        #expect(theme.hex(.gridFocusBorder) == "#0080FF")
    }

    @Test("An imported theme survives the TablePro format unchanged")
    func roundTripsThroughTheFormat() throws {
        let theme = try Self.theme(
            """
            {"name": "Round Trip", "author": "Someone", "type": "light", "colors": {
              "editor.background": "#FDF6E3", "editor.foreground": "#657B83", "editor.selectionBackground": "#EEE8D5AA",
              "list.activeSelectionBackground": "#DFCA88", "diffEditor.insertedLineBackground": "#9BB95533"
            }, "tokenColors": [{"scope": "comment", "settings": {"foreground": "#93A1A1", "fontStyle": "italic"}}]}
            """
        )

        let decoded = try ThemeFileFormat.decode(try ThemeFileFormat.encode(theme))

        #expect(decoded == theme)
    }
}
