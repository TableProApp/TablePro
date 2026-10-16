import AppKit
import Combine
import Foundation
import os
import SwiftUI
import TableProEditorKit
import TableProTheme

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

/// Owns the selection (mode and the two theme ids), the active palette and the font caches. The
/// catalog is `ThemeCatalog`, the choice is `ThemeResolver`, and the fonts come from settings. It
/// never writes settings back, so the flow is one way, and it follows the catalog itself, so a save,
/// an import or a file changed on disk repaints with no view involved.
@MainActor
internal final class ThemeEngine: ObservableObject {
    internal static let shared = ThemeEngine(catalog: .shared, source: .shared, changes: AppEvents.shared.themeChanged)

    @Published internal private(set) var pair: ThemePair
    @Published internal private(set) var effectiveAppearance: ThemeAppearance
    @Published internal private(set) var revision: Int
    @Published internal private(set) var palette: ThemePalette
    @Published internal private(set) var resolved: ResolvedTheme
    @Published internal private(set) var editorFonts: EditorFontCache
    @Published internal private(set) var dataGridFonts: DataGridFontCache

    internal private(set) var mode: AppAppearanceMode = .auto
    internal private(set) var lightThemeId = BuiltInThemes.defaultLightId
    internal private(set) var darkThemeId = BuiltInThemes.defaultDarkId

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

    private let catalog: ThemeCatalog
    private let source: ThemeSource
    private let changes: PassthroughSubject<ThemeChange, Never>
    private var drafts: [String: ThemeDefinition] = [:]
    private var isResolveScheduled = false
    private var catalogCancellable: AnyCancellable?
    private var typography: TypographySettings = .default
    private var generation = 0
    private var systemFingerprint: SystemColorFingerprint?
    private var appearanceObservation: NSKeyValueObservation?
    private var systemColorsObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var lastAccessibilityScale: CGFloat = 1

    /// The shared engine draws the app. Another one, on its own source and change subject, touches
    /// nothing the app draws with.
    internal init(
        catalog: ThemeCatalog,
        source: ThemeSource = ThemeSource(),
        changes: PassthroughSubject<ThemeChange, Never> = PassthroughSubject()
    ) {
        self.catalog = catalog
        self.source = source
        self.changes = changes
        pair = .builtIn
        effectiveAppearance = .light
        revision = 1
        palette = ThemePalette(revision: 1, source: source)
        resolved = ResolvedTheme(definition: BuiltInThemes.light, source: source)
        editorFonts = EditorFontCache(from: .default)
        dataGridFonts = DataGridFontCache(from: .default)

        observeCatalog()
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
        self.lightThemeId = lightThemeId
        self.darkThemeId = darkThemeId
        apply(mode: mode)
    }

    internal func apply(mode: AppAppearanceMode) {
        self.mode = mode
        applyApplicationAppearance(mode)
        observeApplicationAppearance()
        resolve()
    }

    internal func select(lightThemeId: String, darkThemeId: String) {
        self.lightThemeId = lightThemeId
        self.darkThemeId = darkThemeId
        resolve()
    }

    internal func apply(typography: TypographySettings) {
        guard typography != self.typography else { return }
        self.typography = typography
        editorFonts = EditorFontCache(from: typography)
        dataGridFonts = DataGridFontCache(from: typography)
        bumpRevision()
        publishChange()
    }

    // MARK: - Draft preview

    /// Stands in for the theme with the draft's id until `endPreview(id:)`, so an editor repaints the
    /// real windows on every change without a file write. A draft no pair slot selects draws nothing.
    internal func beginPreview(_ draft: ThemeDefinition) {
        guard drafts[draft.id] != draft else { return }
        drafts[draft.id] = draft
        scheduleResolve()
    }

    internal func endPreview(id: String) {
        guard drafts.removeValue(forKey: id) != nil else { return }
        scheduleResolve()
    }

    // MARK: - Resolution

    /// The resolver's output applied to the engine. Every entry point funnels here, and it is the
    /// seam a test uses to put a known pair in front of the grid without touching settings.
    internal func adopt(_ selection: ThemeSelection) {
        let appearanceChanged = selection.effectiveAppearance != effectiveAppearance
        let pairChanged = selection.pair != pair

        guard appearanceChanged || pairChanged else { return }

        pair = selection.pair
        effectiveAppearance = selection.effectiveAppearance
        source.update(selection.pair)

        if pairChanged {
            bumpRevision()
        }
        resolved = ResolvedTheme(definition: activeTheme, source: source)

        publishChange()
        Self.logger.info("Theme \(self.activeTheme.id, privacy: .public) revision \(self.revision)")
    }

    private func resolve() {
        adopt(ThemeResolver.resolve(
            lightThemeId: lightThemeId,
            darkThemeId: darkThemeId,
            themes: resolverInput(),
            effectiveAppearance: mode.effectiveAppearance(systemIsDark: Self.systemIsDark())
        ))
    }

    private func resolverInput() -> [ThemeDefinition] {
        var themes = catalog.themes.map { drafts[$0.id] ?? $0 }
        let listed = Set(themes.map(\.id))
        themes += drafts.values.filter { !listed.contains($0.id) }
        return ThemeOrdering.sorted(themes)
    }

    /// A color well reports every drag tick, and one catalog reload can publish more than once, so a
    /// burst costs one resolution. Common modes, because a well drag runs the event-tracking mode.
    private func scheduleResolve() {
        guard !isResolveScheduled else { return }
        isResolveScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isResolveScheduled = false
                self.resolve()
            }
        }
    }

    /// `@Published` sends before the property changes, so the scheduled resolution reads the new list.
    private func observeCatalog() {
        catalogCancellable = catalog.$themes
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleResolve() }
    }

    private func bumpRevision() {
        revision += 1
        palette = ThemePalette(revision: revision, source: source)
    }

    private func publishChange() {
        generation += 1
        systemFingerprint = SystemColorFingerprint.current()
        changes.send(change)
    }

    /// A system color change gets new palette objects, because SwiftUI caches a resolved
    /// `Color(nsColor:)` by object identity and would keep the old accent otherwise.
    private func systemColorsMayHaveChanged() {
        let appearance = mode.effectiveAppearance(systemIsDark: Self.systemIsDark())
        let appearanceChanged = appearance != effectiveAppearance
        guard appearanceChanged || SystemColorFingerprint.current() != systemFingerprint else { return }

        if appearanceChanged {
            effectiveAppearance = appearance
            resolved = ResolvedTheme(definition: activeTheme, source: source)
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
