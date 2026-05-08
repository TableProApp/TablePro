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

    /// Posted when terminal settings change (font, theme, cursor, etc.)
    /// Used by terminal views to live-update configuration.
    static let terminalSettingsDidChange = Notification.Name("terminalSettingsDidChange")

    /// Posted when AI settings change (active provider, inline suggestions toggle, etc.)
    /// Used by editor coordinators to re-resolve inline suggestion sources.
    static let aiSettingsDidChange = Notification.Name("aiSettingsDidChange")
}
