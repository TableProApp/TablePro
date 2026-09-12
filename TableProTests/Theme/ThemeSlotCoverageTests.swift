//
//  ThemeSlotCoverageTests.swift
//  TableProTests
//
//  Whole colour groups shipped declared, editable and read by nothing: `sidebar` and `toolbar` had
//  no reader at all, `ui` had one, and `ui.accentColor` was declared by every bundled theme and had
//  no property to decode into. A slot exists here only because a call site reads it.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Theme slot coverage")
struct ThemeSlotCoverageTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    /// The files that declare the slots. Everything else counts as a reader, including
    /// `ThemeEngine.makeEditorTheme`, which is where the editor and syntax slots are read.
    private static let definitionFiles: Set<String> = [
        "ThemeDefinition.swift", "BuiltInThemes.swift", "ThemeColorValue.swift",
        "ThemeDocument.swift", "ThemePalette.swift", "ThemeCatalog.swift", "ThemeResolver.swift",
    ]

    private static let appSource: String = {
        let directory = repositoryRoot.appendingPathComponent("TablePro", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return ""
        }

        var source = ""
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard !Self.definitionFiles.contains(url.lastPathComponent) else { continue }
            source += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return source
    }()

    @Test("Every slot is read by app code")
    func everySlotHasAReader() {
        #expect(!Self.appSource.isEmpty)

        for slot in ThemeSlot.allCases {
            #expect(Self.appSource.contains(".\(String(describing: slot))"), "Nothing reads \(slot.rawValue)")
        }
    }

    @Test("Slot paths are unique and namespaced")
    func slotPathsAreWellFormed() {
        let paths = ThemeSlot.allCases.map(\.rawValue)
        #expect(Set(paths).count == paths.count)

        for path in paths {
            #expect(path.hasPrefix("content."), "\(path)")
            #expect(path.components(separatedBy: ".").count >= 3, "\(path)")
        }
    }

    @Test("Every slot belongs to exactly one group")
    func groupsPartitionTheSlots() {
        let grouped = ThemeSlotGroup.allCases.flatMap(\.slots)
        #expect(Set(grouped) == Set(ThemeSlot.allCases))
        #expect(grouped.count == ThemeSlot.allCases.count)
    }

    // MARK: - Bundled themes

    @Test("Every bundled theme passes the gate", arguments: ["tablepro.dracula", "tablepro.nord"])
    func bundledThemesPassTheGate(id: String) throws {
        let url = Self.repositoryRoot.appendingPathComponent("TablePro/Resources/Themes/\(id).json")
        let document = try ThemeDocument(data: try Data(contentsOf: url))

        #expect(document.id == id)
        #expect(document.colors.count == ThemeSlot.allCases.count)
    }

    /// The bundled themes are the only ones shipped, so a hand-typed colour that never renders is
    /// caught here rather than by a user.
    @Test("Bundled themes declare a real colour for every slot", arguments: ["tablepro.dracula", "tablepro.nord"])
    func bundledThemesDeclareHexColors(id: String) throws {
        let url = Self.repositoryRoot.appendingPathComponent("TablePro/Resources/Themes/\(id).json")
        let theme = try ThemeDocument(data: try Data(contentsOf: url)).resolved()

        for slot in ThemeSlot.allCases {
            let value = theme[keyPath: slot.keyPath]
            #expect(!value.isSystem, "\(id) leaves \(slot.rawValue) on a system colour")
        }
    }

    /// Default Light and Default Dark keep the surrounds on system colours so the unthemed app is
    /// unchanged and keeps the system's Increase Contrast handling.
    @Test("The default themes keep the grid surrounds on system colours")
    func defaultThemesUseSystemSurrounds() {
        for theme in BuiltInThemes.all {
            #expect(theme.dataGrid.background.isSystem)
            #expect(theme.dataGrid.text.isSystem)
            #expect(theme.dataGrid.alternateRow.isSystem)
            #expect(theme.dataGrid.selection.isSystem)
            #expect(theme.editor.background.isSystem == false)
        }
    }

    @Test("The default themes declare the appearance of their slot")
    func defaultThemesDeclareTheirAppearance() {
        #expect(BuiltInThemes.light.appearance == .light)
        #expect(BuiltInThemes.dark.appearance == .dark)
        #expect(BuiltInThemes.default(for: .dark).id == BuiltInThemes.defaultDarkId)
    }
}
