import AppKit
import Combine
import Foundation
import os
import SwiftUI
import TableProEditorKit

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
@MainActor
internal final class ThemeEngine: ObservableObject {
    internal static let shared = ThemeEngine()

    @Published internal private(set) var pair: ThemePair
    @Published internal private(set) var effectiveAppearance: ThemeAppearance
    @Published internal private(set) var revision: Int
    @Published internal private(set) var palette: ThemePalette
    @Published internal private(set) var resolved: ResolvedTheme
    @Published internal private(set) var editorFonts: EditorFontCache
    @Published internal private(set) var dataGridFonts: DataGridFontCache

    internal var activeTheme: ThemeDefinition { pair[effectiveAppearance] }

    internal var change: ThemeChange {
        ThemeChange(revision: revision, appearance: effectiveAppearance, generation: generation)
    }

    /// Every control that shows or edits a stored value takes this, so one value reads the same in
    /// the grid cell, its inline editor, the row inspector, a cell popover and a pop-out window.
    internal var valueFont: NSFont { dataGridFonts.regular }
    internal var valueFontSwiftUI: Font { Font(valueFont) }
    internal var valueFontEmphasizedSwiftUI: Font { Font(dataGridFonts.medium) }

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeEngine")

    private var mode: AppAppearanceMode = .auto
    private var typography: TypographySettings = .default
    private var generation = 0
    private var systemFingerprint: SystemColorFingerprint?
    private var appearanceObservation: NSKeyValueObservation?
    private var systemColorsObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var lastAccessibilityScale: CGFloat = 1

    private init() {
        pair = .builtIn
        effectiveAppearance = .light
        revision = 1
        palette = ThemePalette(revision: 1)
        resolved = ResolvedTheme(definition: BuiltInThemes.light)
        editorFonts = EditorFontCache(from: .default)
        dataGridFonts = DataGridFontCache(from: .default)

        observeSystemColorChanges()
        observeAccessibilityChanges()
    }

    /// What the system colors depend on besides the theme. A notification or KVO callback that
    /// leaves it unchanged is not a change: `NSApp.appearance = nil` fires the observer even when
    /// it was already nil, and a light/dark flip can arrive through more than one channel.
    private struct SystemColorFingerprint: Equatable {
        let appearance: NSAppearance.Name?
        let accent: String
        let highlight: String
        let increaseContrast: Bool

        @MainActor
        static func current() -> SystemColorFingerprint {
            let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
            var accent = ""
            var highlight = ""
            appearance.performAsCurrentDrawingAppearance {
                accent = HexColor.string(from: .controlAccentColor)
                highlight = HexColor.string(from: .selectedTextBackgroundColor)
            }
            return SystemColorFingerprint(
                appearance: appearance.name,
                accent: accent,
                highlight: highlight,
                increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            )
        }
    }

    // MARK: - Settings entry points

    internal func apply(mode: AppAppearanceMode, lightThemeId: String, darkThemeId: String) {
        self.mode = mode
        applyApplicationAppearance(mode)
        observeApplicationAppearance()

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
    /// visible without a settings round trip.
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
        resolved = ResolvedTheme(definition: activeTheme)

        publishChange()
        Self.logger.info("Theme \(self.activeTheme.id, privacy: .public) revision \(self.revision)")
    }

    private func bumpRevision() {
        revision += 1
        palette = ThemePalette(revision: revision)
    }

    private func publishChange() {
        generation += 1
        systemFingerprint = SystemColorFingerprint.current()
        AppEvents.shared.themeChanged.send(change)
    }

    /// A system color change gets new palette objects, because SwiftUI caches a resolved
    /// `Color(nsColor:)` by object identity and would keep the old accent otherwise.
    private func systemColorsMayHaveChanged() {
        let appearance = ThemeResolver.effectiveAppearance(mode: mode, systemIsDark: Self.systemIsDark())
        let appearanceChanged = appearance != effectiveAppearance
        guard appearanceChanged || SystemColorFingerprint.current() != systemFingerprint else { return }

        if appearanceChanged {
            effectiveAppearance = appearance
            resolved = ResolvedTheme(definition: activeTheme)
        }
        bumpRevision()
        publishChange()
    }

    // MARK: - Application appearance

    private func applyApplicationAppearance(_ mode: AppAppearanceMode) {
        guard let app = NSApp else { return }
        let target: NSAppearance.Name?
        switch mode {
        case .light: target = .aqua
        case .dark: target = .darkAqua
        case .auto: target = nil
        }
        guard app.appearance?.name != target else { return }
        app.appearance = target.flatMap { NSAppearance(named: $0) }
    }

    private static func systemIsDark() -> Bool {
        NSApp?.effectiveAppearance.isDarkTheme ?? false
    }

    /// `NSApplication.effectiveAppearance` changes on a light/dark flip and, per the
    /// `NSControlTintDidChangeNotification` deprecation text, on an Accent change. Observed in
    /// every mode: a forced Light window still needs to re-bake its colors when the accent moves.
    private func observeApplicationAppearance() {
        guard appearanceObservation == nil else { return }
        appearanceObservation = NSApp?.observe(\.effectiveAppearance) { [weak self] _, _ in
            guard Thread.isMainThread else {
                Task { @MainActor [weak self] in self?.systemColorsMayHaveChanged() }
                return
            }
            MainActor.assumeIsolated {
                self?.systemColorsMayHaveChanged()
            }
        }
    }

    /// The Highlight color, and any other system color, changes through this notification rather
    /// than through the appearance.
    private func observeSystemColorChanges() {
        systemColorsObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemColorsMayHaveChanged()
            }
        }
    }

    // MARK: - Accessibility

    private func observeAccessibilityChanges() {
        lastAccessibilityScale = EditorFontCache.accessibilityScale()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.accessibilityDisplayOptionsDidChange()
            }
        }
    }

    /// Increase Contrast changes every system color's resolved value, so baked colors are
    /// rebuilt even when the text scale did not move.
    private func accessibilityDisplayOptionsDidChange() {
        let scale = EditorFontCache.accessibilityScale()
        let scaleChanged = abs(scale - lastAccessibilityScale) > 0.01
        lastAccessibilityScale = scale

        guard scaleChanged else {
            systemColorsMayHaveChanged()
            return
        }
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
