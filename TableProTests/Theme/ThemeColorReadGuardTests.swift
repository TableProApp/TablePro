//
//  ThemeColorReadGuardTests.swift
//  TableProTests
//
//  A theme colors content and the window backdrop: the code views, the data grid and the closed list of
//  content surfaces below. Chrome, controls, Settings and forms stay system, so a theme read or theming
//  helper in any other file fails here.
//

import Foundation
@testable import TablePro
import Testing

struct ThemeColorReadGuardTests {
    private static let allowedDirectories = [
        "TablePro/Theme/",
        "TablePro/Views/Settings/Appearance/",
        "TablePro/Views/Results/Cells/",
        "TablePro/Views/Results/Selection/",
    ]

    // The data grid's own files under TablePro/Views/Results/; the satellites around it are panes.
    private static let gridFilePrefixes = ["DataGrid", "SortableHeader", "CellOverlay"]

    private static let codeViewFiles = [
        "SQLEditorView",
        "TableProEditorTheme",
        "HighlightedSQLTextView",
        "SQLStatementPreview",
        "SQLCodePreview",
        "JSONCodeEditor",
        "AIChatCodeBlockView",
        "AIChatToolUseBlockView",
        "AIChatToolResultBlockView",
        "DDLTextView",
        "TriggerEditorView",
        "RewindReviewSheet",
        "AgentProposedStatementsView",
        "SQLCompletionItem",
        "VimCursorManager",
        "GhostTextRenderer",
        "CodeWell",
        "ValueWell",
        "TextValueEditor",
        "ValueSourceEditor",
        "TextViewerWindowController",
        "SvgViewerContentView",
        "CellImageWindowController",
        "ServerOutputTextView",
        "HexEditorContentView",
        "PhpViewerView",
        "FavoriteEditDialog",
        "OptionsPaneView",
    ]

    private static let contentWindowFiles = [
        "TabWindowController",
        "DataFileWindowController",
        "CompareSyncWindowController",
        "ValueViewerWindowController",
    ]

    private static let contentSurfaceFiles = [
        "MainEditorContentView",
        "GridStandInBackground",
        "EditorTabStripSurfaces",
        "VersionHistoryTabView",
        "ObjectSourceTabView",
        "DataFileContentView",
        "FilterPanelView",
        "TableStructureView",
        "TriggerDetailView",
        "ClickHousePartsView",
        "PrivilegeScopeOutlineView",
        "TreeOutlineView",
        "TreeOutlineCoordinator",
        "TreeValueTone+Theme",
        "JSONRowInspectorView",
        "JSONNodeRowView",
        "SingleLineEditorView",
        "FieldEditorContent",
        "MultiLineEditorView",
        "JsonEditorView",
        "ImageFieldView",
        "PhpSerializedFieldView",
        "CompareStatusStyle",
        "TextDiffView",
        "FileConflictDiffSheet",
        "AIChatWalkthroughBlockView",
        "ERDiagramPalette",
        "ERDiagramNodeRenderer",
        "ERDiagramScene",
        "ERDiagramSceneView",
        "MagnifiableCanvasView",
        "QueryPlanDiagramView",
        "QueryPlanDetailPane",
        "QueryPlanOutlineCoordinator",
        "ResultChartCanvas",
        "ThemePreviewCard",
    ]

    private static var allowedFiles: [String] {
        codeViewFiles + contentWindowFiles + contentSurfaceFiles
    }

    static func isAllowed(_ path: String) -> Bool {
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
            try ThemeSourceScan.Rule(
                "theme surface",
                #"\btheme(?:Background|Foreground)\(|\bvalueWell\(|\bCodeWell\b|\bstyle:\s*\.code\b"#
            ),
            try ThemeSourceScan.Rule(
                "theme chrome",
                #"\bTheme(?:ShapeStyle|TextViewStyle|TableChrome|TableRowView|WindowBackdrop)\b"#
            ),
            try ThemeSourceScan.Rule(
                "theme helper",
                #"\b(?:gridStandInBackground|diffLineForeground)\(|\bCompareStatusStyle\.(?:lineTint|rowTint)|\b(?:ValueSourceEditor|ERDiagramPalette)\b"#
            ),
        ]
    }

    @Test("Only content surfaces and the window backdrop read the theme")
    func themeStaysOnContentSurfaces() throws {
        let rules = try Self.rules()
        let tree = try ThemeSourceScan.scan(["TablePro"], rules: rules) { !Self.isAllowed($0) }
        let offenders = ThemeSourceScan.violations(in: tree.lines, rules: rules)

        #expect(tree.fileCount > 1_000, "Scanned only \(tree.fileCount) files; the tree did not resolve")
        #expect(
            offenders.isEmpty,
            """
            These theme a surface outside the content files this suite lists. Chrome, controls, Settings \
            and forms use a system color (.primary, .secondary, Color(nsColor: .separatorColor), \
            NSColor.labelColor, .systemRed); a new content surface goes on the list:
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

    @Test("A content surface that stops reading the theme leaves the list")
    func contentEntriesStillReadTheTheme() throws {
        let rules = try Self.rules()
        let names = Set(Self.contentWindowFiles + Self.contentSurfaceFiles)
        let tree = try ThemeSourceScan.scan(["TablePro"], rules: rules) { path in
            names.contains(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        }
        let readers = Set(
            tree.lines
                .filter { line in rules.contains { $0.matches(line.text) } }
                .map { (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension }
        )

        #expect(names.subtracting(readers).isEmpty, "Read no theme API: \(names.subtracting(readers).sorted())")
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
        content.themeBackground(slot, native: .background)
        let chrome = ThemeTableChrome(tableView: outline, family: .records)
        CodeWell(sql, font: font)
        TextValueEditor(text: $text, style: .code)
        field.valueWell(clipsContent: true)
        let style: Kind = .codeBlock
        placeholder.gridStandInBackground()
        // CodeWell and .valueWell() named in a comment
        content.background(.background)
        """
        let lines = ThemeSourceScan.flaggedLines(in: sample, rules: try Self.rules())

        #expect(lines == [1, 3, 6, 7, 8, 9, 10, 11, 13])

        let messages = ThemeSourceScan.violations(
            in: ThemeSourceScan.codeLines(of: sample, path: "Pane.swift"),
            rules: try Self.rules()
        )
        #expect(messages.first?.hasPrefix("Pane.swift:1: ") == true, "\(messages)")
    }

    @Test("The allowlist covers content surfaces and nothing beside them")
    func allowlistShape() {
        #expect(Self.isAllowed("TablePro/Views/Results/DataGridRowView.swift"))
        #expect(Self.isAllowed("TablePro/Views/Results/Extensions/DataGridView+Selection.swift"))
        #expect(Self.isAllowed("TablePro/Views/Results/Cells/DataGridCellPalette.swift"))
        #expect(Self.isAllowed("TablePro/Views/Editor/SQLEditorView.swift"))
        #expect(Self.isAllowed("TablePro/Views/Structure/DDLTextView.swift"))
        #expect(Self.isAllowed("TablePro/Views/Structure/TriggerDetailView.swift"))
        #expect(Self.isAllowed("TablePro/Views/Results/TreeOutline/TreeValueTone+Theme.swift"))
        #expect(Self.isAllowed("TablePro/Core/Services/Infrastructure/TabWindowController.swift"))
        #expect(Self.isAllowed("TablePro/Theme/ThemeEngine+EditorTheme.swift"))

        #expect(!Self.isAllowed("TablePro/Views/Editor/QueryEditorBar.swift"))
        #expect(!Self.isAllowed("TablePro/Views/Editor/History/HistoryDetailPane.swift"))
        #expect(!Self.isAllowed("TablePro/Views/Results/TreeOutline/TreeOutlineCellView.swift"))
        #expect(!Self.isAllowed("TablePro/Views/Results/InlineErrorBanner.swift"))
        #expect(!Self.isAllowed("TablePro/Views/RowInspector/JSON/JSONRowColors.swift"))
        #expect(!Self.isAllowed("TablePro/Views/UsersRoles/PrivilegeScopeRowView.swift"))
        #expect(!Self.isAllowed("TablePro/Views/Sidebar/DatabaseTreeOutlineView.swift"))
        #expect(!Self.isAllowed("TablePro/Views/Settings/GeneralSettingsView.swift"))
        #expect(!Self.isAllowed("TablePro/Views/Welcome/WelcomeOutlineView.swift"))
        #expect(!Self.isAllowed("TablePro/Views/ConnectionForm/ConnectionFormWindowController.swift"))
    }
}
