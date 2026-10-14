import AppKit
import Combine

/// Fills a content window's backdrop with the theme's window background, which the sidebar,
/// inspector and toolbar glass take their tone from on macOS 26 and later. Earlier sidebars blend
/// with the desktop instead, so there the window keeps its own color.
///
/// The window gets a color only while the active theme sets one: any color other than a system one
/// removes the window's own content-background material, so a default theme leaves it untouched.
@MainActor
internal final class ThemeWindowBackdrop {
    private weak var window: NSWindow?
    private var original: NSColor?
    private var themeCancellable: AnyCancellable?

    internal init(window: NSWindow) {
        self.window = window
        guard #available(macOS 26.0, *) else { return }
        apply()
        themeCancellable = AppEvents.shared.themeChanged
            .sink { [weak self] _ in self?.apply() }
    }

    internal func apply() {
        guard #available(macOS 26.0, *), let window else { return }
        let engine = ThemeEngine.shared
        guard engine.activeTheme.isOverridden(.windowBackdrop, in: window.effectiveAppearance) else {
            restore(window)
            return
        }
        if original == nil {
            original = window.backgroundColor
        }
        window.backgroundColor = engine.palette[.windowBackdrop]
    }

    private func restore(_ window: NSWindow) {
        guard let original else { return }
        window.backgroundColor = original
        self.original = nil
    }
}
