//
//  AppSettings.swift
//  TablePro
//
//  Application settings models - pure data structures
//

import AppKit
import Foundation
import SwiftUI

// MARK: - General Settings

/// Startup behavior when app launches
enum StartupBehavior: String, Codable, CaseIterable, Identifiable {
    case showWelcome = "showWelcome"
    case reopenLast = "reopenLast"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .showWelcome: return String(localized: "Show Welcome Screen")
        case .reopenLast: return String(localized: "Reopen Last Session")
        }
    }
}

/// App language options
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system = "system"
    case english = "en"
    case vietnamese = "vi"
    case chineseSimplified = "zh-Hans"
    case turkish = "tr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        case .chineseSimplified: return "简体中文"
        case .turkish: return "Türkçe"
        }
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

/// General app settings
struct GeneralSettings: Codable, Equatable {
    var startupBehavior: StartupBehavior
    var language: AppLanguage
    var automaticallyCheckForUpdates: Bool

    /// Query execution timeout in seconds (0 = no limit)
    var queryTimeoutSeconds: Int

    /// Whether to share anonymous usage analytics
    var shareAnalytics: Bool

    static let `default` = GeneralSettings(
        startupBehavior: .showWelcome,
        language: .system,
        automaticallyCheckForUpdates: true,
        queryTimeoutSeconds: 60,
        shareAnalytics: true
    )

    init(
        startupBehavior: StartupBehavior = .showWelcome,
        language: AppLanguage = .system,
        automaticallyCheckForUpdates: Bool = true,
        queryTimeoutSeconds: Int = 60,
        shareAnalytics: Bool = true
    ) {
        self.startupBehavior = startupBehavior
        self.language = language
        self.automaticallyCheckForUpdates = automaticallyCheckForUpdates
        self.queryTimeoutSeconds = queryTimeoutSeconds
        self.shareAnalytics = shareAnalytics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startupBehavior = try container.decode(StartupBehavior.self, forKey: .startupBehavior)
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        automaticallyCheckForUpdates = try container.decodeIfPresent(Bool.self, forKey: .automaticallyCheckForUpdates) ?? true
        queryTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .queryTimeoutSeconds) ?? 60
        shareAnalytics = try container.decodeIfPresent(Bool.self, forKey: .shareAnalytics) ?? true
    }
}

// MARK: - Appearance Settings

/// Controls NSApp.appearance independent of the active theme.
enum AppAppearanceMode: String, Codable, CaseIterable {
    case light
    case dark
    case auto

    var displayName: String {
        switch self {
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        case .auto: return String(localized: "Auto")
        }
    }
}

/// Appearance settings
struct AppearanceSettings: Codable, Equatable {
    var activeThemeId: String
    var appearanceMode: AppAppearanceMode

    static let `default` = AppearanceSettings(
        activeThemeId: "tablepro.default-light",
        appearanceMode: .auto
    )

    init(activeThemeId: String = "tablepro.default-light", appearanceMode: AppAppearanceMode = .auto) {
        self.activeThemeId = activeThemeId
        self.appearanceMode = appearanceMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Migration: try new field first, then fall back to old theme field
        if let themeId = try container.decodeIfPresent(String.self, forKey: .activeThemeId) {
            activeThemeId = themeId
        } else if let oldTheme = try? container.decodeIfPresent(String.self, forKey: .theme) {
            // Migrate from old AppTheme enum
            switch oldTheme {
            case "dark": activeThemeId = "tablepro.default-dark"
            default: activeThemeId = "tablepro.default-light"
            }
        } else {
            activeThemeId = "tablepro.default-light"
        }
        appearanceMode = try container.decodeIfPresent(AppAppearanceMode.self, forKey: .appearanceMode) ?? .auto
    }

    private enum CodingKeys: String, CodingKey {
        case activeThemeId, theme, appearanceMode
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activeThemeId, forKey: .activeThemeId)
        try container.encode(appearanceMode, forKey: .appearanceMode)
    }
}

// MARK: - Editor Settings

/// Available monospace fonts for the SQL editor
enum EditorFont: String, Codable, CaseIterable, Identifiable {
    case systemMono = "System Mono"
    case sfMono = "SF Mono"
    case menlo = "Menlo"
    case monaco = "Monaco"
    case courierNew = "Courier New"

    var id: String { rawValue }

    var displayName: String { rawValue }

    /// Get the actual NSFont for this option
    func font(size: CGFloat) -> NSFont {
        switch self {
        case .systemMono:
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .sfMono:
            return NSFont(name: "SFMono-Regular", size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .menlo:
            return NSFont(name: "Menlo", size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .monaco:
            return NSFont(name: "Monaco", size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .courierNew:
            return NSFont(name: "Courier New", size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    /// Check if this font is available on the system
    var isAvailable: Bool {
        switch self {
        case .systemMono:
            return true
        case .sfMono:
            return NSFont(name: "SFMono-Regular", size: 12) != nil
        case .menlo:
            return NSFont(name: "Menlo", size: 12) != nil
        case .monaco:
            return NSFont(name: "Monaco", size: 12) != nil
        case .courierNew:
            return NSFont(name: "Courier New", size: 12) != nil
        }
    }
}

/// Editor settings
struct EditorSettings: Codable, Equatable {
    var showLineNumbers: Bool
    var highlightCurrentLine: Bool
    var tabWidth: Int // 2, 4, or 8 spaces
    var autoIndent: Bool
    var wordWrap: Bool
    var vimModeEnabled: Bool

    static let `default` = EditorSettings(
        showLineNumbers: true,
        highlightCurrentLine: true,
        tabWidth: 4,
        autoIndent: true,
        wordWrap: false,
        vimModeEnabled: false
    )

    init(
        showLineNumbers: Bool = true,
        highlightCurrentLine: Bool = true,
        tabWidth: Int = 4,
        autoIndent: Bool = true,
        wordWrap: Bool = false,
        vimModeEnabled: Bool = false
    ) {
        self.showLineNumbers = showLineNumbers
        self.highlightCurrentLine = highlightCurrentLine
        self.tabWidth = tabWidth
        self.autoIndent = autoIndent
        self.wordWrap = wordWrap
        self.vimModeEnabled = vimModeEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Old fontFamily/fontSize keys are ignored (moved to ThemeFonts)
        showLineNumbers = try container.decodeIfPresent(Bool.self, forKey: .showLineNumbers) ?? true
        highlightCurrentLine = try container.decodeIfPresent(Bool.self, forKey: .highlightCurrentLine) ?? true
        tabWidth = try container.decodeIfPresent(Int.self, forKey: .tabWidth) ?? 4
        autoIndent = try container.decodeIfPresent(Bool.self, forKey: .autoIndent) ?? true
        wordWrap = try container.decodeIfPresent(Bool.self, forKey: .wordWrap) ?? false
        vimModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .vimModeEnabled) ?? false
    }

    /// Clamped tab width (1-16)
    var clampedTabWidth: Int {
        min(max(tabWidth, 1), 16)
    }
}

// MARK: - Data Grid Settings

/// Row height options for data grid
enum DataGridRowHeight: Int, Codable, CaseIterable, Identifiable {
    case compact = 20
    case normal = 24
    case comfortable = 28
    case spacious = 32

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .compact: return String(localized: "Compact")
        case .normal: return String(localized: "Normal")
        case .comfortable: return String(localized: "Comfortable")
        case .spacious: return String(localized: "Spacious")
        }
    }
}

/// Date format options
enum DateFormatOption: String, Codable, CaseIterable, Identifiable {
    case iso8601 = "yyyy-MM-dd HH:mm:ss"
    case iso8601Date = "yyyy-MM-dd"
    case usLong = "MM/dd/yyyy hh:mm:ss a"
    case usShort = "MM/dd/yyyy"
    case euLong = "dd/MM/yyyy HH:mm:ss"
    case euShort = "dd/MM/yyyy"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iso8601: return String(localized: "ISO 8601 (2024-12-31 23:59:59)")
        case .iso8601Date: return String(localized: "ISO Date (2024-12-31)")
        case .usLong: return String(localized: "US Long (12/31/2024 11:59:59 PM)")
        case .usShort: return String(localized: "US Short (12/31/2024)")
        case .euLong: return String(localized: "EU Long (31/12/2024 23:59:59)")
        case .euShort: return String(localized: "EU Short (31/12/2024)")
        }
    }

    var formatString: String { rawValue }
}

/// Data grid settings
struct DataGridSettings: Codable, Equatable {
    var rowHeight: DataGridRowHeight
    var dateFormat: DateFormatOption
    var nullDisplay: String
    var defaultPageSize: Int
    var showAlternateRows: Bool
    var showRowNumbers: Bool
    var autoShowInspector: Bool

    static let `default` = DataGridSettings(
        rowHeight: .normal,
        dateFormat: .iso8601,
        nullDisplay: "NULL",
        defaultPageSize: 1_000,
        showAlternateRows: true,
        showRowNumbers: true,
        autoShowInspector: false
    )

    init(
        rowHeight: DataGridRowHeight = .normal,
        dateFormat: DateFormatOption = .iso8601,
        nullDisplay: String = "NULL",
        defaultPageSize: Int = 1_000,
        showAlternateRows: Bool = true,
        showRowNumbers: Bool = true,
        autoShowInspector: Bool = false
    ) {
        self.rowHeight = rowHeight
        self.dateFormat = dateFormat
        self.nullDisplay = nullDisplay
        self.defaultPageSize = defaultPageSize
        self.showAlternateRows = showAlternateRows
        self.showRowNumbers = showRowNumbers
        self.autoShowInspector = autoShowInspector
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Old fontFamily/fontSize keys are ignored (moved to ThemeFonts)
        rowHeight = try container.decodeIfPresent(DataGridRowHeight.self, forKey: .rowHeight) ?? .normal
        dateFormat = try container.decodeIfPresent(DateFormatOption.self, forKey: .dateFormat) ?? .iso8601
        nullDisplay = try container.decodeIfPresent(String.self, forKey: .nullDisplay) ?? "NULL"
        defaultPageSize = try container.decodeIfPresent(Int.self, forKey: .defaultPageSize) ?? 1_000
        showAlternateRows = try container.decodeIfPresent(Bool.self, forKey: .showAlternateRows) ?? true
        showRowNumbers = try container.decodeIfPresent(Bool.self, forKey: .showRowNumbers) ?? true
        autoShowInspector = try container.decodeIfPresent(Bool.self, forKey: .autoShowInspector) ?? false
    }

    // MARK: - Validated Properties

    /// Validated and sanitized nullDisplay (max 20 chars, no newlines)
    var validatedNullDisplay: String {
        let sanitized = nullDisplay.sanitized
        let maxLength = SettingsValidationRules.nullDisplayMaxLength

        // Clamp to max length
        if sanitized.isEmpty {
            return "NULL" // Fallback to default
        } else if sanitized.count > maxLength {
            return String(sanitized.prefix(maxLength))
        }
        return sanitized
    }

    /// Validated defaultPageSize (10 to 100,000)
    var validatedDefaultPageSize: Int {
        defaultPageSize.clamped(to: SettingsValidationRules.defaultPageSizeRange)
    }

    /// Validation error for nullDisplay (for UI feedback)
    var nullDisplayValidationError: String? {
        let sanitized = nullDisplay.sanitized
        let maxLength = SettingsValidationRules.nullDisplayMaxLength

        if sanitized.isEmpty {
            return String(localized: "NULL display cannot be empty")
        } else if sanitized.count > maxLength {
            return String(localized: "NULL display must be \(maxLength) characters or less")
        } else if nullDisplay != sanitized {
            return String(localized: "NULL display contains invalid characters (newlines/tabs)")
        }
        return nil
    }

    /// Validation error for defaultPageSize (for UI feedback)
    var defaultPageSizeValidationError: String? {
        let range = SettingsValidationRules.defaultPageSizeRange
        if defaultPageSize < range.lowerBound || defaultPageSize > range.upperBound {
            return String(localized: "Page size must be between \(range.lowerBound.formatted()) and \(range.upperBound.formatted())")
        }
        return nil
    }
}

// MARK: - History Settings

/// History settings
struct HistorySettings: Codable, Equatable {
    var maxEntries: Int // 0 = unlimited
    var maxDays: Int // 0 = unlimited
    var autoCleanup: Bool

    static let `default` = HistorySettings(
        maxEntries: 10_000,
        maxDays: 90,
        autoCleanup: true
    )

    init(maxEntries: Int = 10_000, maxDays: Int = 90, autoCleanup: Bool = true) {
        self.maxEntries = maxEntries
        self.maxDays = maxDays
        self.autoCleanup = autoCleanup
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxEntries = try container.decodeIfPresent(Int.self, forKey: .maxEntries) ?? 10_000
        maxDays = try container.decodeIfPresent(Int.self, forKey: .maxDays) ?? 90
        autoCleanup = try container.decodeIfPresent(Bool.self, forKey: .autoCleanup) ?? true
    }

    // MARK: - Validated Properties

    /// Validated maxEntries (>= 0)
    var validatedMaxEntries: Int {
        max(0, maxEntries)
    }

    /// Validated maxDays (>= 0)
    var validatedMaxDays: Int {
        max(0, maxDays)
    }

    /// Validation error for maxEntries
    var maxEntriesValidationError: String? {
        if maxEntries < 0 {
            return String(localized: "Maximum entries cannot be negative")
        }
        return nil
    }

    /// Validation error for maxDays
    var maxDaysValidationError: String? {
        if maxDays < 0 {
            return String(localized: "Maximum days cannot be negative")
        }
        return nil
    }
}

// MARK: - Tab Settings

/// Tab behavior settings
struct TabSettings: Codable, Equatable {
    var enablePreviewTabs: Bool = true
    var groupAllConnectionTabs: Bool = false
    static let `default` = TabSettings()

    init(enablePreviewTabs: Bool = true, groupAllConnectionTabs: Bool = false) {
        self.enablePreviewTabs = enablePreviewTabs
        self.groupAllConnectionTabs = groupAllConnectionTabs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enablePreviewTabs = try container.decodeIfPresent(Bool.self, forKey: .enablePreviewTabs) ?? true
        groupAllConnectionTabs = try container.decodeIfPresent(Bool.self, forKey: .groupAllConnectionTabs) ?? false
    }
}
