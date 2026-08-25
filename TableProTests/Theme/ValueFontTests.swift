//
//  ValueFontTests.swift
//  TableProTests
//
//  The row inspector, the cell popovers and the Compare row diff all render a stored value, so they
//  follow the data grid font rather than the editor font. TablePlus was asked this exact question on
//  its own row detail sidebar (TablePlus/TablePlus#1180) and answered "it should be the same font as
//  table-data"; the grid's own inline cell editor already agreed. These tests pin that choice and the
//  places that carry it, because both settings ship at the same family and size, so a regression is
//  invisible until a user splits them.
//

import AppKit
import Foundation
@testable import TablePro
import Testing

/// The first two tests activate a theme on the shared `ThemeEngine`. What keeps that from reaching a
/// suite running in parallel is that both bodies are synchronous and `@MainActor`, so nothing else on
/// the main actor can interleave between activating the test theme and restoring the original one, the
/// same way `DataGridRowTintThemeTests` holds. Adding an `await` inside `withTheme` would break it.
@Suite("Stored value font", .serialized)
@MainActor
struct ValueFontTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    private static func theme(editorSize: Int, gridSize: Int) -> ThemeDefinition {
        var theme = ThemeDefinition.default
        theme.id = "user.value-font-tests"
        theme.fonts = ThemeFonts(
            editorFontFamily: "Menlo",
            editorFontSize: editorSize,
            dataGridFontFamily: "Courier",
            dataGridFontSize: gridSize
        )
        return theme
    }

    private func withTheme(_ theme: ThemeDefinition, _ body: () -> Void) {
        let previous = ThemeEngine.shared.activeTheme
        ThemeEngine.shared.activateTheme(theme)
        body()
        ThemeEngine.shared.activateTheme(previous)
    }

    // MARK: - Which setting the value font comes from

    @Test("The value font is the data grid font, not the editor font")
    func valueFontFollowsTheDataGridFont() {
        withTheme(Self.theme(editorSize: 18, gridSize: 11)) {
            let engine = ThemeEngine.shared
            #expect(engine.valueFont == engine.dataGridFonts.regular)
            #expect(engine.valueFont != engine.editorFonts.font)
        }
    }

    /// The contested half of #2393, stated as behaviour rather than as an implementation equality: the
    /// issue asked for the editor font and this ships the data grid font instead, so moving the editor
    /// setting must leave every value control where it was.
    @Test("Changing only the editor size leaves the value font alone")
    func valueFontIgnoresTheEditorSize() {
        var afterSmall: NSFont?
        var afterLarge: NSFont?
        withTheme(Self.theme(editorSize: 11, gridSize: 13)) { afterSmall = ThemeEngine.shared.valueFont }
        withTheme(Self.theme(editorSize: 18, gridSize: 13)) { afterLarge = ThemeEngine.shared.valueFont }

        #expect(afterSmall == afterLarge)
    }

    // MARK: - The places that carry the rule

    /// The inspector sets the font once for the whole editor subtree, so a field editor added later
    /// inherits it without knowing the rule exists. Losing this puts every inspector field back on the
    /// system face at once, and the structured viewers have to keep opting out, because they carry
    /// their own toolbar and placeholders and present the same way in a pop-out window.
    @Test("The inspector sets the value font on its editor subtree")
    func inspectorSetsTheValueFontOnce() throws {
        let source = try source(of: "TablePro/Views/RightSidebar/EditableFieldView.swift")
        #expect(source.contains(".font(inheritedValueFont(for: kind))"))
        #expect(source.contains("ThemeEngine.shared.valueFontSwiftUI"))
        #expect(source.contains("case .json, .phpSerialized:"))
    }

    /// Everything outside the inspector has no shared root to inherit from: a popover, a pop-out window
    /// and the Compare pane are each their own presentation, and an `NSViewRepresentable` never sees a
    /// SwiftUI `.font` at all. Each of these therefore resolves it by name.
    @Test("Every value view outside the inspector resolves the value font")
    func standaloneValueViewsResolveTheValueFont() throws {
        let paths = [
            "TablePro/Views/RightSidebar/FieldEditors/MultiLineEditorView.swift",
            "TablePro/Views/RightSidebar/FieldEditors/PendingStateOverlay.swift",
            "TablePro/Views/RightSidebar/FieldEditors/SetPickerView.swift",
            "TablePro/Views/Results/CellOverlayEditor.swift",
            "TablePro/Views/Results/CellOverlayViewer.swift",
            "TablePro/Views/Results/TextViewerWindowController.swift",
            "TablePro/Views/Results/HexEditorContentView.swift",
            "TablePro/Views/Results/ForeignKeyPreviewView.swift",
            "TablePro/Views/Results/ArrayValueEditorView.swift",
            "TablePro/Views/Results/SetPopoverContentView.swift",
            "TablePro/Views/Results/JSONTreeView.swift",
            "TablePro/Views/Results/PhpTreeView.swift",
            "TablePro/Views/Results/PhpViewerView.swift",
            "TablePro/Views/Compare/CompareRowDiffPane.swift",
        ]

        var offenders: [String] = []
        for path in paths {
            if try !source(of: path).contains("ThemeEngine.shared.valueFont") {
                offenders.append(path)
            }
        }

        #expect(offenders.isEmpty, "These render a stored value and must resolve its font: \(offenders)")
    }

    /// Naming a font inside a field editor overrides what the subtree set, which is how the defect
    /// looked in the first place. `.subheadline` was on the single-line, multi-line and schema editors,
    /// and `preferredFont(forTextStyle:)` was what the multi-line editor handed AppKit. The remaining
    /// `.caption` and `.caption2` in this directory are all button and badge chrome, so they are not
    /// listed.
    @Test("No field editor overrides the subtree with a system text style")
    func fieldEditorsNameNoSystemTextStyle() throws {
        let banned = [".font(.subheadline)", "preferredFont(forTextStyle:", ".font(.system("]
        let directory = Self.repositoryRoot
            .appendingPathComponent("TablePro/Views/RightSidebar/FieldEditors")
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )

        var offenders: [String] = []
        for url in contents where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            if banned.contains(where: source.contains) {
                offenders.append(url.lastPathComponent)
            }
        }

        #expect(offenders.isEmpty, "These should inherit the value font instead: \(offenders)")
    }

    /// The sidebar's JSON editor caches its whole configuration in `@State`, so it repaints only when
    /// something tells it to. It used to watch the colour scheme alone, which left it on the old font
    /// after a size, theme or accessibility change until the row was reselected.
    @Test("The JSON editor rebuilds its configuration on every appearance change")
    func jsonEditorWatchesEveryAppearanceChange() throws {
        let source = try source(of: "TablePro/Views/Results/JSONCodeEditor.swift")

        #expect(source.contains("onChange(of: colorScheme)"))
        #expect(source.contains("onChange(of: AppSettingsManager.shared.editor)"))
        #expect(source.contains("onReceive(AppEvents.shared.themeChanged)"))
        #expect(source.contains("onReceive(AppEvents.shared.accessibilityTextSizeChanged)"))
    }

    /// A dump line is a fixed count of characters, so the popover that holds one has to size itself
    /// from the value font rather than from a width that was right for one hardcoded size.
    @Test("The hex popover sizes itself from a dump line")
    func hexPopoverSizesItselfFromTheDump() throws {
        let source = try source(of: "TablePro/Views/Results/HexEditorContentView.swift")
        #expect(source.contains("HexDumpLayout.lineWidthInCharacters"))
        #expect(!source.contains(".frame(width: 520"))
    }

    private func source(of path: String) throws -> String {
        try String(contentsOf: Self.repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }
}
