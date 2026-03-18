//
//  SettingsNotifications.swift
//  TablePro
//
//  Notification names for settings changes that require AppKit bridging.
//  SwiftUI views observe @Observable AppSettingsManager directly instead.
//

import Foundation

extension Notification.Name {
    /// Posted when data grid settings change (row height, date format, etc.)
    /// Used by AppKit components that cannot observe @Observable directly.
    static let dataGridSettingsDidChange = Notification.Name("dataGridSettingsDidChange")

    /// Posted when editor settings change (font, line numbers, etc.)
    /// Used by AppKit components that cannot observe @Observable directly.
    static let editorSettingsDidChange = Notification.Name("editorSettingsDidChange")

    /// Posted when the system accessibility text size preference changes.
    /// Observers should reload fonts via ThemeEngine.shared.reloadFontCaches().
    static let accessibilityTextSizeDidChange = Notification.Name("accessibilityTextSizeDidChange")

    /// Posted when the active theme changes (colors, fonts, or entire theme switch).
    /// Used by AppKit components that cannot observe @Observable directly.
    static let themeDidChange = Notification.Name("themeDidChange")
}
