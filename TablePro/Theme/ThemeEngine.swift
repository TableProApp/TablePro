//
//  ThemeEngine.swift
//  TablePro
//
//  Central @Observable singleton managing the active theme.
//  Replaces Theme.swift, SQLEditorTheme, DataGridFontCache, ToolbarDesignTokens.
//

import AppKit
import CodeEditSourceEditor
import Foundation
import Observation
import os
import SwiftUI

// MARK: - Font Caches

/// Tags stored on NSTextField.tag to identify which font variant a cell uses.
internal enum DataGridFontVariant {
    static let regular = 0
    static let italic = 1
    static let medium = 2
    static let rowNumber = 3
}

internal struct EditorFontCache {
    let font: NSFont
    let lineNumberFont: NSFont
    let scaleFactor: CGFloat

    init(from fonts: ThemeFonts) {
        let scale = Self.computeAccessibilityScale()
        scaleFactor = scale
        let scaledSize = round(CGFloat(min(max(fonts.editorFontSize, 11), 18)) * scale)
        font = EditorFontResolver.resolve(familyId: fonts.editorFontFamily, size: scaledSize)
        let lineNumSize = max(round((scaledSize - 2)), 9)
        lineNumberFont = NSFont.monospacedSystemFont(ofSize: lineNumSize, weight: .regular)
    }

    static func computeAccessibilityScale() -> CGFloat {
        let preferredBodyFont = NSFont.preferredFont(forTextStyle: .body)
        let scale = preferredBodyFont.pointSize / 13.0
        return min(max(scale, 0.5), 3.0)
    }
}

internal struct DataGridFontCacheResolved {
    let regular: NSFont
    let italic: NSFont
    let medium: NSFont
    let rowNumber: NSFont
    let monoCharWidth: CGFloat

    init(from fonts: ThemeFonts) {
        let scale = EditorFontCache.computeAccessibilityScale()
        let scaledSize = round(CGFloat(min(max(fonts.dataGridFontSize, 10), 18)) * scale)
        regular = EditorFontResolver.resolve(familyId: fonts.dataGridFontFamily, size: scaledSize)
        italic = regular.withTraits(.italic)
        medium = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        let rowNumSize = max(round(scaledSize - 1), 9)
        rowNumber = NSFont.monospacedDigitSystemFont(ofSize: rowNumSize, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: regular]
        monoCharWidth = ("M" as NSString).size(withAttributes: attrs).width
    }
}

// MARK: - ThemeEngine

@Observable
@MainActor
internal final class ThemeEngine {
    static let shared = ThemeEngine()

    // MARK: - Active Theme

    private(set) var activeTheme: ThemeDefinition

    /// Pre-resolved colors (rebuilt on theme change)
    private(set) var colors: ResolvedThemeColors

    /// Cached editor fonts
    private(set) var editorFonts: EditorFontCache

    /// Cached data grid fonts
    private(set) var dataGridFonts: DataGridFontCacheResolved

    // MARK: - Available Themes

    private(set) var availableThemes: [ThemeDefinition]

    // MARK: - Editor Behavioral Settings (read from AppSettingsManager)

    /// These are not theme properties but are needed by makeEditorTheme()
    @ObservationIgnored var highlightCurrentLine: Bool = true
    @ObservationIgnored var showLineNumbers: Bool = true
    @ObservationIgnored var tabWidth: Int = 4
    @ObservationIgnored var autoIndent: Bool = true
    @ObservationIgnored var wordWrap: Bool = false

    // MARK: - Private

    @ObservationIgnored private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeEngine")
    @ObservationIgnored private var accessibilityObserver: NSObjectProtocol?
    @ObservationIgnored private var lastAccessibilityScale: CGFloat = 1.0

    // MARK: - Init

    private init() {
        let theme = ThemeDefinition.default

        self.activeTheme = theme
        self.colors = ResolvedThemeColors(from: theme)
        self.editorFonts = EditorFontCache(from: theme.fonts)
        self.dataGridFonts = DataGridFontCacheResolved(from: theme.fonts)
        self.availableThemes = [theme]

        observeAccessibilityChanges()

        Task {
            let themes = await Task.detached { ThemeStorage.loadAllThemes() }.value
            self.availableThemes = themes
        }
    }

    // MARK: - Theme Lifecycle

    func activateTheme(id: String) {
        guard let theme = availableThemes.first(where: { $0.id == id })
            ?? ThemeStorage.loadTheme(id: id)
        else {
            Self.logger.warning("Theme not found: \(id)")
            return
        }

        activateTheme(theme)
    }

    func activateTheme(_ theme: ThemeDefinition) {
        activeTheme = theme
        colors = ResolvedThemeColors(from: theme)
        editorFonts = EditorFontCache(from: theme.fonts)
        dataGridFonts = DataGridFontCacheResolved(from: theme.fonts)

        notifyThemeDidChange()

        Self.logger.info("Activated theme: \(theme.name) (\(theme.id))")
    }

    // MARK: - Theme CRUD

    func saveUserTheme(_ theme: ThemeDefinition) throws {
        try ThemeStorage.saveUserTheme(theme)
        reloadAvailableThemes()

        // If editing the active theme, re-activate to apply changes
        if theme.id == activeTheme.id {
            activateTheme(theme)
        }
    }

    func deleteUserTheme(id: String) throws {
        guard !id.hasPrefix("tablepro."), !id.hasPrefix("registry.") else { return }
        try ThemeStorage.deleteUserTheme(id: id)
        reloadAvailableThemes()

        // If deleted a preferred theme, reset that slot to default
        var appearance = AppSettingsManager.shared.appearance
        var changed = false
        if id == appearance.preferredLightThemeId {
            appearance.preferredLightThemeId = "tablepro.default-light"
            changed = true
        }
        if id == appearance.preferredDarkThemeId {
            appearance.preferredDarkThemeId = "tablepro.default-dark"
            changed = true
        }
        if changed {
            AppSettingsManager.shared.appearance = appearance
        } else if id == activeTheme.id {
            // Deleted a non-preferred but currently active theme — re-anchor to preferred
            let appearance = AppSettingsManager.shared.appearance
            updateAppearanceAndTheme(
                mode: appearance.appearanceMode,
                lightThemeId: appearance.preferredLightThemeId,
                darkThemeId: appearance.preferredDarkThemeId
            )
        }
    }

    func duplicateTheme(_ theme: ThemeDefinition, newName: String) -> ThemeDefinition {
        var copy = theme
        copy.id = "user.\(UUID().uuidString.lowercased().prefix(8))"
        copy.name = newName
        copy.author = theme.author
        return copy
    }

    func importTheme(from url: URL) throws -> ThemeDefinition {
        let theme = try ThemeStorage.importTheme(from: url)
        reloadAvailableThemes()
        return theme
    }

    func exportTheme(_ theme: ThemeDefinition, to url: URL) throws {
        try ThemeStorage.exportTheme(theme, to: url)
    }

    var registryThemes: [ThemeDefinition] {
        availableThemes.filter(\.isRegistry)
    }

    func uninstallRegistryTheme(registryPluginId: String) throws {
        try ThemeRegistryInstaller.shared.uninstall(registryPluginId: registryPluginId)
    }

    func reloadAvailableThemes() {
        Task {
            let themes = await Task.detached { ThemeStorage.loadAllThemes() }.value
            self.availableThemes = themes
        }
    }

    // MARK: - Editor Font Size Zoom

    func adjustEditorFontSize(by delta: Int) {
        var theme = activeTheme
        let newSize = max(9, min(24, theme.fonts.editorFontSize + delta))
        guard newSize != theme.fonts.editorFontSize else { return }
        theme.fonts.editorFontSize = newSize
        activeTheme = theme
        editorFonts = EditorFontCache(from: theme.fonts)
        notifyThemeDidChange()

        // Persist so the zoom survives re-activation (e.g. system appearance change)
        if theme.isEditable {
            try? ThemeStorage.saveUserTheme(theme)
        }
    }

    // MARK: - Font Cache Reload (accessibility)

    func reloadFontCaches() {
        editorFonts = EditorFontCache(from: activeTheme.fonts)
        dataGridFonts = DataGridFontCacheResolved(from: activeTheme.fonts)
        notifyThemeDidChange()
    }

    // MARK: - Update Editor Behavioral Settings

    func updateEditorSettings(
        highlightCurrentLine: Bool,
        showLineNumbers: Bool,
        tabWidth: Int,
        autoIndent: Bool,
        wordWrap: Bool
    ) {
        self.highlightCurrentLine = highlightCurrentLine
        self.showLineNumbers = showLineNumbers
        self.tabWidth = tabWidth
        self.autoIndent = autoIndent
        self.wordWrap = wordWrap
    }

    // MARK: - CodeEditSourceEditor Theme

    func makeEditorTheme() -> EditorTheme {
        let c = colors.editor

        let textAttr = EditorTheme.Attribute(color: srgb(c.text))
        let commentAttr = EditorTheme.Attribute(color: srgb(c.comment))
        let keywordAttr = EditorTheme.Attribute(color: srgb(c.keyword), bold: true)
        let stringAttr = EditorTheme.Attribute(color: srgb(c.string))
        let numberAttr = EditorTheme.Attribute(color: srgb(c.number))
        let variableAttr = EditorTheme.Attribute(color: srgb(c.null))
        let typeAttr = EditorTheme.Attribute(color: srgb(c.type))

        let lineHighlight: NSColor = highlightCurrentLine ? c.currentLineHighlight : .clear

        return EditorTheme(
            text: textAttr,
            insertionPoint: srgb(c.cursor),
            invisibles: EditorTheme.Attribute(color: srgb(c.invisibles)),
            background: srgb(c.background),
            lineHighlight: srgb(lineHighlight),
            selection: srgb(c.selection),
            keywords: keywordAttr,
            commands: keywordAttr,
            types: typeAttr,
            attributes: variableAttr,
            variables: variableAttr,
            values: variableAttr,
            numbers: numberAttr,
            strings: stringAttr,
            characters: stringAttr,
            comments: commentAttr
        )
    }

    // MARK: - Appearance

    @ObservationIgnored private(set) var appearanceMode: AppAppearanceMode = .auto
    private(set) var effectiveAppearance: ThemeAppearance = .light
    @ObservationIgnored private var currentLightThemeId: String = "tablepro.default-light"
    @ObservationIgnored private var currentDarkThemeId: String = "tablepro.default-dark"
    @ObservationIgnored private var systemAppearanceObserver: NSObjectProtocol?

    /// Central entry point: resolves effective appearance, picks the correct theme, activates it,
    /// and derives NSApp.appearance from the theme's own appearance metadata.
    func updateAppearanceAndTheme(
        mode: AppAppearanceMode,
        lightThemeId: String,
        darkThemeId: String
    ) {
        appearanceMode = mode
        currentLightThemeId = lightThemeId
        currentDarkThemeId = darkThemeId

        let resolved = resolveEffectiveAppearance(mode)
        effectiveAppearance = resolved

        let themeId = resolved == .dark ? darkThemeId : lightThemeId
        activateTheme(id: themeId)
        applyNSAppAppearance(mode: mode)

        updateSystemAppearanceObserver(mode: mode)
    }

    /// Resolve which appearance is in effect right now.
    private func resolveEffectiveAppearance(_ mode: AppAppearanceMode) -> ThemeAppearance {
        switch mode {
        case .light: return .light
        case .dark: return .dark
        case .auto: return systemIsDark() ? .dark : .light
        }
    }

    /// Check if the system is currently in dark mode.
    /// Reads the global `AppleInterfaceStyle` default directly so we get the real
    /// system setting, not the app's own forced appearance.
    private func systemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// Set NSApp.appearance based on the appearance mode (not the theme).
    /// Auto mode sets nil so the system controls the chrome.
    private func applyNSAppAppearance(mode: AppAppearanceMode) {
        switch mode {
        case .light:
            NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp?.appearance = NSAppearance(named: .darkAqua)
        case .auto:
            NSApp?.appearance = nil
        }
    }

    // MARK: - System Appearance Observer

    private func updateSystemAppearanceObserver(mode: AppAppearanceMode) {
        // Remove existing observer
        if let observer = systemAppearanceObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            systemAppearanceObserver = nil
        }

        guard mode == .auto else { return }

        // Install observer for system appearance changes
        systemAppearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.appearanceMode == .auto else { return }
                let newAppearance = self.systemIsDark() ? ThemeAppearance.dark : ThemeAppearance.light
                guard newAppearance != self.effectiveAppearance else { return }
                self.effectiveAppearance = newAppearance
                let themeId = newAppearance == .dark ? self.currentDarkThemeId : self.currentLightThemeId
                self.activateTheme(id: themeId)
                self.applyNSAppAppearance(mode: .auto)
            }
        }
    }

    // MARK: - Notifications

    private func notifyThemeDidChange() {
        NotificationCenter.default.post(name: .themeDidChange, object: self)
    }

    // MARK: - Accessibility

    private func observeAccessibilityChanges() {
        lastAccessibilityScale = EditorFontCache.computeAccessibilityScale()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newScale = EditorFontCache.computeAccessibilityScale()
                guard abs(newScale - lastAccessibilityScale) > 0.01 else { return }
                lastAccessibilityScale = newScale
                Self.logger.debug("Accessibility text size changed, scale: \(newScale, format: .fixed(precision: 2))")
                reloadFontCaches()
                NotificationCenter.default.post(name: .accessibilityTextSizeDidChange, object: self)
            }
        }
    }

    // MARK: - Helpers

    private func srgb(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }
}

// MARK: - Database Type Colors (preserved from old Theme.swift)

extension DatabaseType {
    @MainActor var themeColor: Color {
        PluginManager.shared.brandColor(for: self)
    }
}

// MARK: - View Extensions (preserved from old Theme.swift)

extension View {
    func cardStyle() -> some View {
        self
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    func toolbarButtonStyle() -> some View {
        self
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
    }
}
