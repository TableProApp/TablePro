//
//  ScreenshotEnvironment.swift
//  TablePro
//

import AppKit

/// The two things a marketing screenshot has to pin that a test cannot otherwise reach.
///
/// The window size, because every shot on tablepro.app is 3024x1722 and the page declares those
/// numbers as the image's `width` and `height`. A capture at any other size changes the aspect
/// ratio the section reserves for it, and the layout shifts while the file loads.
///
/// The appearance, because the site ships a light and a dark file for each shot and picks one with
/// a `prefers-color-scheme` query. The two have to be one frame in two palettes. Following the
/// system appearance would make them two different pictures whenever the machine flipped between
/// captures.
///
/// Both reads are gated on the storage sandbox. In a shipped build `isIsolated` is false and these
/// variables do nothing; a build that sets `TABLEPRO_UI_TESTING` without a sandbox has already
/// refused to launch.
internal enum ScreenshotEnvironment {
    internal static let frameVariable = "TABLEPRO_SCREENSHOT_FRAME"
    internal static let appearanceVariable = "TABLEPRO_SCREENSHOT_APPEARANCE"

    internal static var windowSize: CGSize? {
        guard let raw = sandboxedValue(of: frameVariable) else { return nil }
        return size(from: raw)
    }

    internal static var appearanceMode: AppAppearanceMode? {
        guard let raw = sandboxedValue(of: appearanceVariable) else { return nil }
        return AppAppearanceMode(rawValue: raw)
    }

    /// Returns nil on anything it cannot read, so a typo opens the window at its normal size and
    /// the test's assertion on the captured file names the mismatch. Silently falling back to a
    /// default would ship a shot at the wrong size, which is the failure nobody notices until the
    /// page is live.
    internal static func size(from raw: String) -> CGSize? {
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width > 0,
              height > 0
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    /// Centred on the visible frame rather than placed at a fixed origin. `screencapture` reads the
    /// window's own bounds, so a window hanging off the screen edge comes back clipped by the
    /// display instead of failing.
    @MainActor
    internal static func pinWindowSize(_ window: NSWindow) {
        guard let size = windowSize else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }

        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private static func sandboxedValue(of variable: String) -> String? {
        guard AppStorageEnvironment.shared.isIsolated else { return nil }
        let raw = ProcessInfo.processInfo.environment[variable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }
}
