import Foundation
@testable import TableProTheme
import Testing

// Two fixtures, each read through an exhaustive switch, so a new slot cannot ship without a decision
// about what a VS Code theme gives it.
struct VSCodeThemeMappingTests {
    // Every slot's first source answers, each with its own color.
    private static let firstSources = """
    {"type": "dark", "colors": {
      "editorPane.background": "#101010",
      "editor.background": "#202020",
      "editor.foreground": "#E0E0E0",
      "editorCursor.foreground": "#F0A000",
      "editor.selectionBackground": "#3050A080",
      "editor.lineHighlightBackground": "#FFFFFF10",
      "editor.lineHighlightBorder": "#999999",
      "editor.rangeHighlightBackground": "#FFFF0020",
      "editorLineNumber.foreground": "#808080",
      "editorWhitespace.foreground": "#404040",
      "keybindingTable.rowsBackground": "#252525",
      "tree.tableOddRowsBackground": "#999999",
      "tree.tableColumnsBorder": "#303030",
      "input.placeholderForeground": "#707070",
      "gitDecoration.modifiedResourceForeground": "#E0C000",
      "diffEditor.insertedLineBackground": "#00FF0020",
      "diffEditor.insertedTextBackground": "#999999",
      "diffEditor.removedLineBackground": "#FF000020",
      "diffEditor.removedTextBackground": "#999999",
      "gitDecoration.deletedResourceForeground": "#FF4040"
    }, "tokenColors": [
      {"scope": "keyword.other.DML", "settings": {"foreground": "#C00001"}},
      {"scope": "string.quoted.single", "settings": {"foreground": "#C00002"}},
      {"scope": "constant.numeric", "settings": {"foreground": "#C00003"}},
      {"scope": "comment.line.double-dash", "settings": {"foreground": "#C00004"}},
      {"scope": "constant.language.null", "settings": {"foreground": "#C00005"}},
      {"scope": "keyword.operator.comparison", "settings": {"foreground": "#C00006"}},
      {"scope": "entity.name.function", "settings": {"foreground": "#C00007"}},
      {"scope": "support.function.aggregate", "settings": {"foreground": "#999999"}},
      {"scope": "entity.name.type", "settings": {"foreground": "#C00008"}},
      {"scope": "storage.type", "settings": {"foreground": "#999999"}},
      {"scope": "constant.language.boolean.true", "settings": {"foreground": "#C00009"}},
      {"scope": "constant.language.boolean.false", "settings": {"foreground": "#C0000A"}}
    ]}
    """

    private static func expectedFromFirstSources(_ slot: ThemeSlot) -> String? {
        switch slot {
        case .windowBackdrop: return "#101010"
        case .editorBackground: return "#202020"
        case .editorText: return "#E0E0E0"
        case .editorCursor: return "#F0A000"
        case .editorSelection: return "#3050A080"
        case .editorCurrentLine: return "#FFFFFF10"
        case .editorCurrentStatement: return "#FFFF0020"
        case .editorLineNumber: return "#808080"
        case .editorInvisibles: return "#404040"
        case .syntaxKeyword: return "#C00001"
        case .syntaxString: return "#C00002"
        case .syntaxNumber: return "#C00003"
        case .syntaxComment: return "#C00004"
        case .syntaxNull: return "#C00005"
        case .syntaxOperator: return "#C00006"
        case .syntaxFunction: return "#C00007"
        case .syntaxType: return "#C00008"
        case .gridBackground: return "#202020"
        case .gridText: return "#E0E0E0"
        case .gridAlternateRow: return "#252525"
        case .gridLine: return "#303030"
        case .gridNullValue: return "#707070"
        case .gridBoolTrue: return "#C00009"
        case .gridBoolFalse: return "#C0000A"
        case .gridRowNumber: return "#808080"
        // 0xFF scaled by 0.3 and by 0.5, rounded.
        case .gridModified: return "#E0C0004D"
        case .gridInserted: return "#00FF0020"
        case .gridDeleted: return "#FF000020"
        case .gridDeletedText: return "#FF404080"
        }
    }

    // Only the later sources answer; slots with none stay unset and draw their fallback.
    private static let laterSources = """
    {"colors": {
      "editor.background": "#F8F8F8",
      "editor.foreground": "#202020",
      "editor.lineHighlightBorder": "#E0E0E0",
      "tree.tableOddRowsBackground": "#00000008",
      "foreground": "#404040",
      "diffEditor.insertedTextBackground": "#00AA0033",
      "diffEditor.removedTextBackground": "#AA000033"
    }, "tokenColors": [
      {"scope": "support.function.aggregate", "settings": {"foreground": "#900001"}},
      {"scope": "storage.type", "settings": {"foreground": "#900002"}}
    ]}
    """

    private static func expectedFromLaterSources(_ slot: ThemeSlot) -> String? {
        switch slot {
        case .windowBackdrop: return "#F8F8F8"
        case .editorBackground: return "#F8F8F8"
        case .editorText: return "#202020"
        case .editorCursor: return nil
        case .editorSelection: return nil
        case .editorCurrentLine: return "#E0E0E0"
        case .editorCurrentStatement: return nil
        case .editorLineNumber: return nil
        case .editorInvisibles: return nil
        case .syntaxKeyword: return "#202020"
        case .syntaxString: return "#202020"
        case .syntaxNumber: return "#202020"
        case .syntaxComment: return "#202020"
        case .syntaxNull: return "#202020"
        case .syntaxOperator: return "#202020"
        case .syntaxFunction: return "#900001"
        case .syntaxType: return "#900002"
        case .gridBackground: return "#F8F8F8"
        case .gridText: return "#202020"
        case .gridAlternateRow: return "#00000008"
        case .gridLine: return nil
        case .gridNullValue: return "#40404080"
        case .gridBoolTrue: return nil
        case .gridBoolFalse: return nil
        case .gridRowNumber: return nil
        case .gridModified: return nil
        case .gridInserted: return "#00AA0033"
        case .gridDeleted: return "#AA000033"
        case .gridDeletedText: return nil
        }
    }

    private static func importTheme(_ json: String) throws -> ThemeDefinition {
        let folder = try ThemeImportFolder()
        defer { folder.remove() }
        try folder.write(json, as: "fixture.json")
        return try folder.importTheme("fixture.json")
    }

    @Test("Every slot takes its first VS Code source", arguments: ThemeSlot.allCases)
    func firstSourceWins(_ slot: ThemeSlot) throws {
        let theme = try Self.importTheme(Self.firstSources)

        #expect(theme.hex(slot) == Self.expectedFromFirstSources(slot))
    }

    @Test("Every slot falls through to its later VS Code sources, else to its fallback", arguments: ThemeSlot.allCases)
    func laterSourcesApply(_ slot: ThemeSlot) throws {
        let theme = try Self.importTheme(Self.laterSources)

        #expect(theme.hex(slot) == Self.expectedFromLaterSources(slot))
        #expect(theme.appearance == .light)
    }

    @Test("A syntax slot's sources always end in a color, and slot references never loop", arguments: ThemeSlot.allCases)
    func sourceListsAreWellFormed(_ slot: ThemeSlot) {
        var visited: Set<ThemeSlot> = [slot]
        var current = slot
        while case let .slot(next) = current.vscodeSources.last {
            #expect(visited.insert(next).inserted, "\(slot) loops through \(next)")
            guard visited.count <= ThemeSlot.allCases.count else { return }
            current = next
        }

        if slot.section == .syntax {
            #expect(current.vscodeSources.last == .defaultTokenForeground, "\(slot)")
        }
        for case let .token(stack) in slot.vscodeSources {
            #expect(stack.first == "source.sql", "\(slot)")
        }
    }
}
