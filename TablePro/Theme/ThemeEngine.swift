import AppKit
import CodeEditSourceEditor
import Combine
import Foundation
import Observation
import os
import SwiftUI

internal enum DataGridFontVariant {
    static let regular = 0
    static let italic = 1
    static let medium = 2
    static let rowNumber = 3
}

internal struct EditorFontCache: Equatable {
    internal let font: NSFont
    internal let lineNumberFont: NSFont
    internal let scaleFactor: CGFloat

    internal init(from typography: TypographySettings) {
        let scale = Self.accessibilityScale()
        scaleFactor = scale

        let size = round(CGFloat(typography.clampedEditorFontSize) * scale)
        font = EditorFontResolver.resolve(familyId: typography.editorFontFamily, size: size)
        lineNumberFont = NSFont.monospacedSystemFont(ofSize: max(round(size - 2), 9), weight: .regular)
    }

    internal static func accessibilityScale() -> CGFloat {
        let preferred = NSFont.preferredFont(forTextStyle: .body)
        return min(max(preferred.pointSize / 13.0, 0.5), 3.0)
    }
}

internal struct DataGridFontCache: Equatable {
    internal let regular: NSFont
    internal let italic: NSFont
    internal let medium: NSFont
    internal let rowNumber: NSFont
    internal let monoCharWidth: CGFloat

    internal init(from typography: TypographySettings) {
        let scale = EditorFontCache.accessibilityScale()
        let size = round(CGFloat(typography.clampedDataGridFontSize) * scale)

        regular = EditorFontResolver.resolve(familyId: typography.dataGridFontFamily, size: size)
        italic = regular.withTraits(.italic)
        medium = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        rowNumber = NSFont.monospacedDigitSystemFont(ofSize: max(round(size - 1), 9), weight: .regular)
        monoCharWidth = ("M" as NSString).size(withAttributes: [.font: regular]).width
    }
}

/// Owns the active palette and the font caches, and nothing else: the catalog is `ThemeCatalog`,
/// the choice is `ThemeResolver`, and the fonts come from settings. It never writes settings back,
/// so the flow is one way.
@Observable
@MainActor
internal final class ThemeEngine {
    internal static let shared = ThemeEngine()

    internal private(set) var pair: ThemePair
    internal private(set) var effectiveAppearance: ThemeAppearance
    internal private(set) var revision: Int
    internal private(set) var palette: ThemePalette
    internal private(set) var resolved: ResolvedTheme
    internal private(set) var editorFonts: EditorFontCache
    internal private(set) var dataGridFonts: DataGridFontCache

    internal var activeTheme: ThemeDefinition { pair[effectiveAppearance] }

    internal var change: ThemeChange {
        ThemeChange(revision: revision, appearance: effectiveAppearance)
    }

    /// Every control that shows or edits a stored value takes this, so one value reads the same in
    /// the grid cell, its inline editor, the row inspector, a cell popover and a pop-out window.
    internal var valueFont: NSFont { dataGridFonts.regular }
    internal var valueFontSwiftUI: Font { Font(valueFont) }
    internal var valueFontEmphasizedSwiftUI: Font { Font(dataGridFonts.medium) }

    @ObservationIgnored
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeEngine")

    @ObservationIgnored private var mode: AppAppearanceMode = .auto
    @ObservationIgnored private var typography: TypographySettings = .default
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var accessibilityObserver: NSObjectProtocol?
    @ObservationIgnored private var lastAccessibilityScale: CGFloat = 1

    private init() {
        pair = .builtIn
        effectiveAppearance = .light
        revision = 1
        palette = ThemePalette(revision: 1)
        resolved = ResolvedTheme(definition: BuiltInThemes.light, appearance: .light)
        editorFonts = EditorFontCache(from: .default)
        dataGridFonts = DataGridFontCache(from: .default)

        observeAccessibilityChanges()
    }

    // MARK: - Settings entry points

    internal func apply(mode: AppAppearanceMode, lightThemeId: String, darkThemeId: String) {
        self.mode = mode
        applyApplicationAppearance(mode)
        updateSystemAppearanceObserver(mode)

        let selection = ThemeResolver.resolve(
            mode: mode,
            lightThemeId: lightThemeId,
            darkThemeId: darkThemeId,
            themes: ThemeCatalog.shared.themes,
            systemIsDark: Self.systemIsDark()
        )

        adopt(selection)
    }

    internal func apply(typography: TypographySettings) {
        guard typography != self.typography else { return }
        self.typography = typography
        editorFonts = EditorFontCache(from: typography)
        dataGridFonts = DataGridFontCache(from: typography)
        bumpRevision()
        publishChange()
    }

    /// Called when the catalog changes under a selection that is already live, so a saved edit is
    /// visible without the settings round trip that used to re-activate a stale cached copy.
    internal func reapply(lightThemeId: String, darkThemeId: String) {
        apply(mode: mode, lightThemeId: lightThemeId, darkThemeId: darkThemeId)
    }

    /// The resolver's output applied to the engine. Every entry point above funnels here, and it
    /// is the seam a test uses to put a known pair in front of the grid without touching settings.
    internal func adopt(_ selection: ThemeSelection) {
        let appearanceChanged = selection.effectiveAppearance != effectiveAppearance
        let pairChanged = selection.pair != pair

        guard appearanceChanged || pairChanged else { return }

        pair = selection.pair
        effectiveAppearance = selection.effectiveAppearance
        ThemeSource.shared.update(selection.pair)

        if pairChanged {
            bumpRevision()
        }
        resolved = ResolvedTheme(definition: activeTheme, appearance: effectiveAppearance)

        publishChange()
        Self.logger.info("Theme \(self.activeTheme.id, privacy: .public) revision \(self.revision)")
    }

    private func bumpRevision() {
        revision += 1
        palette = ThemePalette(revision: revision)
    }

    private func publishChange() {
        AppEvents.shared.themeChanged.send(change)
    }

    // MARK: - Application appearance

    private func applyApplicationAppearance(_ mode: AppAppearanceMode) {
        switch mode {
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        case .auto: NSApp?.appearance = nil
        }
    }

    private static func systemIsDark() -> Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// KVO on `NSApplication.effectiveAppearance` is the channel Apple names in the
    /// `NSControlTintDidChangeNotification` deprecation text. Only the static tier and the change
    /// signal depend on it: the dynamic slot colours answer for the drawing appearance themselves.
    private func updateSystemAppearanceObserver(_ mode: AppAppearanceMode) {
        appearanceObservation = nil
        guard mode == .auto else { return }

        appearanceObservation = NSApp?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.systemAppearanceDidChange()
            }
        }
    }

    private func systemAppearanceDidChange() {
        guard mode == .auto else { return }
        let appearance: ThemeAppearance = Self.systemIsDark() ? .dark : .light
        guard appearance != effectiveAppearance else { return }

        effectiveAppearance = appearance
        resolved = ResolvedTheme(definition: activeTheme, appearance: appearance)
        publishChange()
    }

    // MARK: - CodeEditSourceEditor

    internal func makeEditorTheme() -> EditorTheme {
        let editorSettings = AppSettingsManager.shared.editor
        let text = EditorTheme.Attribute(color: resolved[.editorText])
        let comment = EditorTheme.Attribute(color: resolved[.syntaxComment])
        let keyword = EditorTheme.Attribute(color: resolved[.syntaxKeyword], bold: true)
        let string = EditorTheme.Attribute(color: resolved[.syntaxString])
        let number = EditorTheme.Attribute(color: resolved[.syntaxNumber])
        let variable = EditorTheme.Attribute(color: resolved[.syntaxNull])
        let type = EditorTheme.Attribute(color: resolved[.syntaxType])
        let operatorAttribute = EditorTheme.Attribute(color: resolved[.syntaxOperator])
        let function = EditorTheme.Attribute(color: resolved[.syntaxFunction])

        return EditorTheme(
            text: text,
            insertionPoint: resolved[.editorCursor],
            invisibles: EditorTheme.Attribute(color: resolved[.editorInvisibles]),
            background: resolved[.editorBackground],
            lineHighlight: editorSettings.highlightCurrentLine ? resolved[.editorCurrentLine] : .clear,
            statementHighlight: editorSettings.highlightCurrentStatement ? resolved[.editorCurrentStatement] : .clear,
            selection: resolved[.editorSelection],
            lineNumber: resolved[.editorLineNumber],
            keywords: keyword,
            commands: keyword,
            types: type,
            attributes: variable,
            variables: variable,
            values: variable,
            numbers: number,
            strings: string,
            characters: string,
            comments: comment,
            operators: operatorAttribute,
            functions: function
        )
    }

    // MARK: - Accessibility

    private func observeAccessibilityChanges() {
        lastAccessibilityScale = EditorFontCache.accessibilityScale()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.accessibilityDisplayOptionsDidChange()
            }
        }
    }

    private func accessibilityDisplayOptionsDidChange() {
        let scale = EditorFontCache.accessibilityScale()
        guard abs(scale - lastAccessibilityScale) > 0.01 else { return }
        lastAccessibilityScale = scale

        editorFonts = EditorFontCache(from: typography)
        dataGridFonts = DataGridFontCache(from: typography)
        bumpRevision()
        publishChange()
        AppEvents.shared.accessibilityTextSizeChanged.send(())
    }
}

internal extension DatabaseType {
    @MainActor var themeColor: Color {
        PluginManager.shared.brandColor(for: self)
    }
}
