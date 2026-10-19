import AppKit
import Combine
import TableProTheme

/// Fills a content window's backdrop with the theme's window background, which the sidebar,
/// inspector and toolbar glass take their tone from.
///
/// The window gets a color only while the active theme sets one: any color other than a system one
/// removes the window's own content-background material, so a default theme leaves it untouched.
@MainActor
internal final class ThemeWindowBackdrop {
    /// Before macOS 26 the sidebar blends with the desktop, and a transparent titlebar swaps its
    /// material for a flat fill that would fill chrome, so the window keeps its own color there.
    nonisolated internal static var canReachChrome: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private weak var window: NSWindow?
    private var original: NSColor?
    private var themeCancellable: AnyCancellable?

    internal init(window: NSWindow) {
        self.window = window
        guard Self.canReachChrome else { return }
        apply()
        themeCancellable = AppEvents.shared.themeChanged
            .sink { [weak self] _ in self?.apply() }
    }

    internal func apply() {
        guard Self.canReachChrome, let window else { return }
        guard ThemeBackdropState.isThemed(in: window.effectiveAppearance) else {
            restore(window)
            return
        }
        if original == nil {
            original = window.backgroundColor
        }
        window.backgroundColor = ThemeEngine.shared.palette[.windowBackdrop]
    }

    private func restore(_ window: NSWindow) {
        guard let original else { return }
        window.backgroundColor = original
        self.original = nil
    }
}
