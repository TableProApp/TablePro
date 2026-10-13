//
//  ThemeSlotCoverageTests.swift
//  TableProTests
//
//  A slot exists only because a call site reads it. Whole colour groups once shipped declared,
//  editable and read by nothing, and the substring check that replaced them passed for
//  `.editorText` through `self.editorText` and for `.gridSelection` through `.gridSelectionText`.
//

import Foundation
@testable import TablePro
import Testing

struct ThemeSlotCoverageTests {
    /// The bridge that builds the editor theme is the one file under `TablePro/Theme/` that reads
    /// slots rather than declaring them; the editor slots have no other reader.
    private static let readerInsideThemeDirectory = "TablePro/Theme/ThemeEngine+EditorTheme.swift"

    private static func isReader(_ path: String) -> Bool {
        !path.hasPrefix("TablePro/Theme/") || path == readerInsideThemeDirectory
    }

    private static func referencedSlots(in lines: [ThemeSourceScan.Line]) throws -> Set<String> {
        let expression = try NSRegularExpression(pattern: ThemeSourceScan.slotTokenPattern())
        var found: Set<String> = []
        for line in lines {
            let range = NSRange(line.text.startIndex..., in: line.text)
            for match in expression.matches(in: line.text, range: range) {
                guard let name = Range(match.range(at: 1), in: line.text) else { continue }
                found.insert(String(line.text[name]))
            }
        }
        return found
    }

    @Test("Every slot is read as a whole token outside the theme definitions")
    func everySlotHasAReader() throws {
        let slotRule = try ThemeSourceScan.Rule("theme slot", ThemeSourceScan.slotTokenPattern())
        let tree = try ThemeSourceScan.scan(
            ["TablePro", "Packages"],
            skipping: ["Tests"],
            rules: [slotRule],
            including: Self.isReader
        )
        let referenced = try Self.referencedSlots(in: tree.lines)

        #expect(tree.fileCount > 500, "Scanned only \(tree.fileCount) files; the tree did not resolve")
        for slot in ThemeSlot.allCases {
            #expect(referenced.contains(String(describing: slot)), "Nothing outside TablePro/Theme/ reads .\(slot)")
        }
    }

    @Test("The token match ignores properties, longer names and comments")
    func tokenMatchIsExact() throws {
        let sample = """
        let request = self.editorText
        let fill = palette[.gridSelectionText]
        // resolved[.gridDeleted] was removed
        let text = resolved[.syntaxKeyword]
        let typed = ThemeSlot.gridLine
        """
        let referenced = try Self.referencedSlots(in: ThemeSourceScan.codeLines(of: sample, path: "Sample.swift"))

        #expect(referenced == ["gridSelectionText", "syntaxKeyword", "gridLine"])
    }

    @Test("Slot paths are unique and sit under their group's key")
    func slotPathsAreWellFormed() {
        let paths = ThemeSlot.allCases.map(\.rawValue)
        #expect(Set(paths).count == paths.count)

        for slot in ThemeSlot.allCases {
            switch slot.group {
            case .editor:
                #expect(slot.rawValue.hasPrefix("editor."), "\(slot.rawValue)")
                #expect(!slot.rawValue.hasPrefix("editor.syntax."), "\(slot.rawValue)")
            case .syntax:
                #expect(slot.rawValue.hasPrefix("editor.syntax."), "\(slot.rawValue)")
            case .dataGrid:
                #expect(slot.rawValue.hasPrefix("dataGrid."), "\(slot.rawValue)")
            }
        }
    }

    @Test("Every slot belongs to exactly one group")
    func groupsPartitionTheSlots() {
        let grouped = ThemeSlotGroup.allCases.flatMap(\.slots)
        #expect(Set(grouped) == Set(ThemeSlot.allCases))
        #expect(grouped.count == ThemeSlot.allCases.count)
    }

    // MARK: - Bundled themes

    /// The files on disk are the list, so a third bundled theme is decoded here the day it lands.
    private static func bundledThemeFiles() throws -> [URL] {
        let directory = try ThemeSourceScan.repositoryRoot().appendingPathComponent("TablePro/Resources/Themes")
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test("Every bundled theme decodes, and its id is its file name")
    func bundledThemesDecode() throws {
        let files = try Self.bundledThemeFiles()
        var ids: Set<String> = []

        for file in files {
            let document = try ThemeDocument(data: try Data(contentsOf: file))
            #expect(document.id == file.deletingPathExtension().lastPathComponent)
            #expect(document.id.hasPrefix(ThemeDefinition.builtInPrefix))
            #expect(!document.colors.isEmpty, "\(document.id) overrides nothing")
            ids.insert(document.id)
        }

        #expect(ids.isSuperset(of: ["tablepro.dracula", "tablepro.nord"]))
    }

    // MARK: - Default Light and Default Dark

    private static let syntaxWithoutOperator = Set(ThemeSlotGroup.syntax.slots).subtracting([.syntaxOperator])

    /// Xcode 27.1 `Default (Light).xccolortheme`: keyword, string, number, comment, system function
    /// and system type. SQL `NULL` takes the keyword colour the way Swift's `nil` does.
    @Test("Default Light overrides only syntax, with Xcode's Default (Light) values")
    func defaultLightIsXcodeDefaultLight() {
        let expected: [ThemeSlot: String] = [
            .syntaxKeyword: "#9B2393",
            .syntaxString: "#C41A16",
            .syntaxNumber: "#1C00CF",
            .syntaxComment: "#5D6C79",
            .syntaxFunction: "#6C36A9",
            .syntaxType: "#3900A0",
            .syntaxNull: "#9B2393",
        ]
        let actual = BuiltInThemes.light.overrides.mapValues { $0.hex }

        #expect(Set(actual.keys) == Self.syntaxWithoutOperator)
        #expect(actual == expected)
        #expect(BuiltInThemes.light.appearance == .light)
        #expect(BuiltInThemes.light.id == BuiltInThemes.defaultLightId)
    }

    @Test("Default Dark overrides only syntax, with Xcode's Default (Dark) values")
    func defaultDarkIsXcodeDefaultDark() {
        let expected: [ThemeSlot: String] = [
            .syntaxKeyword: "#FC5FA3",
            .syntaxString: "#FC6A5D",
            .syntaxNumber: "#D0BF69",
            .syntaxComment: "#6C7986",
            .syntaxFunction: "#A167E6",
            .syntaxType: "#D0A8FF",
            .syntaxNull: "#FC5FA3",
        ]
        let actual = BuiltInThemes.dark.overrides.mapValues { $0.hex }

        #expect(Set(actual.keys) == Self.syntaxWithoutOperator)
        #expect(actual == expected)
        #expect(BuiltInThemes.dark.appearance == .dark)
        #expect(BuiltInThemes.default(for: .dark).id == BuiltInThemes.defaultDarkId)
    }
}
