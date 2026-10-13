//
//  ThemeColorReadGuardTests.swift
//  TableProTests
//
//  A theme colors the SQL editor, the other code views and the data grid, and nothing else. When
//  41 other files read theme slots, picking Dracula repainted History, the Row Inspector, the
//  Server Dashboard and every banner in theme colors instead of the system's.
//

import Foundation
@testable import TablePro
import Testing

struct ThemeColorReadGuardTests {
    private static let allowedDirectories = [
        // The theme itself, and its editor in Settings.
        "TablePro/Theme/",
        "TablePro/Views/Settings/Appearance/",
        // The SQL editor, and the data grid's cells and selection.
        "TablePro/Views/Editor/",
        "TablePro/Views/Results/Cells/",
        "TablePro/Views/Results/Selection/",
    ]

    // The query history drawer is a list pane, not a code view, so it draws in system colors.
    private static let deniedDirectories = [
        "TablePro/Views/Editor/History/",
    ]

    // The data grid's own files under TablePro/Views/Results/; the satellites around it are panes.
    private static let gridFilePrefixes = ["DataGrid", "SortableHeader", "CellOverlay"]

    // Code views that live outside the editor directory, and the theme preview in Settings.
    private static let allowedFiles = [
        "HighlightedSQLTextView",
        "SQLStatementPreview",
        "SQLCodePreview",
        "JSONCodeEditor",
        "AIChatCodeBlockView",
        "DDLTextView",
        "TriggerEditorView",
        "RewindReviewSheet",
        "AgentProposedStatementsView",
        "SQLCompletionItem",
        "VimCursorManager",
        "GhostTextRenderer",
        "ThemePreviewCard",
        "CodeWell",
        "ValueWell",
    ]

    static func isAllowed(_ path: String) -> Bool {
        if deniedDirectories.contains(where: { path.hasPrefix($0) }) {
            return false
        }
        if allowedDirectories.contains(where: { path.hasPrefix($0) }) {
            return true
        }
        let fileName = (path as NSString).lastPathComponent
        if path.hasPrefix("TablePro/Views/Results/"), gridFilePrefixes.contains(where: { fileName.hasPrefix($0) }) {
            return true
        }
        return allowedFiles.contains { fileName == "\($0).swift" || fileName.hasPrefix("\($0)+") }
    }

    static func rules() throws -> [ThemeSourceScan.Rule] {
        [
            try ThemeSourceScan.Rule("palette subscript", #"\bpalette\["#),
            try ThemeSourceScan.Rule("palette color", #"\bpalette\.color\("#),
            try ThemeSourceScan.Rule("resolved subscript", #"\.resolved\[|\bresolved\[\s*\."#),
            try ThemeSourceScan.Rule("resolved color", #"\bresolved\.(?:color|cgColor|isOverridden)\("#),
            try ThemeSourceScan.Rule("ThemeSlot", #"\bThemeSlot\b"#),
            try ThemeSourceScan.Rule("theme slot", ThemeSourceScan.slotTokenPattern()),
        ]
    }

    @Test("Only code views and the data grid read theme colors")
    func themeColorsStayInCodeViewsAndTheGrid() throws {
        let rules = try Self.rules()
        let tree = try ThemeSourceScan.scan(["TablePro"], rules: rules) { !Self.isAllowed($0) }
        let offenders = ThemeSourceScan.violations(in: tree.lines, rules: rules)

        #expect(tree.fileCount > 1_000, "Scanned only \(tree.fileCount) files; the tree did not resolve")
        #expect(
            offenders.isEmpty,
            """
            These read a theme color outside the code views and the data grid. Use a system color \
            (.primary, .secondary, Color(nsColor: .separatorColor), NSColor.labelColor, .systemRed):
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("Every allowlisted file still exists")
    func allowlistIsCurrent() throws {
        var fileNames: Set<String> = []
        _ = try ThemeSourceScan.scan(["TablePro"]) { path in
            fileNames.insert((path as NSString).lastPathComponent)
            return false
        }

        for name in Self.allowedFiles {
            #expect(fileNames.contains("\(name).swift"), "\(name).swift is allowlisted but no longer exists")
        }
    }

    @Test("The guard flags a theme read and passes plain code")
    func matcherCatchesAViolation() throws {
        let sample = """
        let fill = themeEngine.palette.color(.panelBackground)
        // palette[.gridText] named in a comment
        let text = ThemeEngine.shared.resolved[.gridText]
        let local = resolved[fieldId]
        let request = self.editorText
        let tint = activeTheme.color(for: .syntaxKeyword)
        """
        let lines = ThemeSourceScan.flaggedLines(in: sample, rules: try Self.rules())

        #expect(lines == [1, 3, 6])

        let messages = ThemeSourceScan.violations(
            in: ThemeSourceScan.codeLines(of: sample, path: "Pane.swift"),
            rules: try Self.rules()
        )
        #expect(messages.first?.hasPrefix("Pane.swift:1: ") == true, "\(messages)")
    }

    @Test("The allowlist covers the grid and code views and nothing beside them")
    func allowlistShape() {
        #expect(Self.isAllowed("TablePro/Views/Results/DataGridRowView.swift"))
        #expect(Self.isAllowed("TablePro/Views/Results/Extensions/DataGridView+Selection.swift"))
        #expect(Self.isAllowed("TablePro/Views/Results/Cells/DataGridCellPalette.swift"))
        #expect(Self.isAllowed("TablePro/Views/Editor/SQLEditorView.swift"))
        #expect(Self.isAllowed("TablePro/Views/Structure/DDLTextView.swift"))
        #expect(Self.isAllowed("TablePro/Theme/ThemeEngine+EditorTheme.swift"))

        #expect(!Self.isAllowed("TablePro/Views/Editor/History/HistoryDetailPane.swift"))
        #expect(!Self.isAllowed("TablePro/Views/Results/TreeOutline/TreeOutlineCellView.swift"))
        #expect(!Self.isAllowed("TablePro/Views/Results/InlineErrorBanner.swift"))
        #expect(!Self.isAllowed("TablePro/Views/RowInspector/JSON/JSONRowColors.swift"))
        #expect(!Self.isAllowed("TablePro/Views/Structure/TriggerDetailView.swift"))
    }
}
