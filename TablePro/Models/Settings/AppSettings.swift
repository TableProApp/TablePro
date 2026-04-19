//
//  AppSettings.swift
//  TablePro
//
//  Application settings models - pure data structures
//

import AppKit
import Foundation
import SwiftUI


// MARK: - Appearance Settings

/// Controls which appearance the app uses: forced light, forced dark, or follow system.
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

/// Appearance settings — couples appearance mode with theme selection.
/// Each appearance (light/dark) has its own preferred theme so the active theme
/// always matches the window chrome.
struct AppearanceSettings: Codable, Equatable {
    var appearanceMode: AppAppearanceMode
    var preferredLightThemeId: String
    var preferredDarkThemeId: String

    static let `default` = AppearanceSettings(
        appearanceMode: .auto,
        preferredLightThemeId: "tablepro.default-light",
        preferredDarkThemeId: "tablepro.default-dark"
    )

    init(
        appearanceMode: AppAppearanceMode = .auto,
        preferredLightThemeId: String = "tablepro.default-light",
        preferredDarkThemeId: String = "tablepro.default-dark"
    ) {
        self.appearanceMode = appearanceMode
        self.preferredLightThemeId = preferredLightThemeId
        self.preferredDarkThemeId = preferredDarkThemeId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearanceMode = try container.decodeIfPresent(AppAppearanceMode.self, forKey: .appearanceMode) ?? .auto
        preferredLightThemeId = try container.decodeIfPresent(String.self, forKey: .preferredLightThemeId)
            ?? "tablepro.default-light"
        preferredDarkThemeId = try container.decodeIfPresent(String.self, forKey: .preferredDarkThemeId)
            ?? "tablepro.default-dark"
    }

    private enum CodingKeys: String, CodingKey {
        case appearanceMode, preferredLightThemeId, preferredDarkThemeId
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
    var enableSmartValueDetection: Bool
    var countRowsIfEstimateLessThan: Int
    var queryResultLimit: Int
    var enforceQueryResultLimit: Bool

    static let `default` = DataGridSettings(
        rowHeight: .normal,
        dateFormat: .iso8601,
        nullDisplay: "NULL",
        defaultPageSize: 1_000,
        showAlternateRows: true,
        showRowNumbers: true,
        autoShowInspector: false,
        enableSmartValueDetection: true,
        countRowsIfEstimateLessThan: 100_000,
        queryResultLimit: 10_000,
        enforceQueryResultLimit: true
    )

    init(
        rowHeight: DataGridRowHeight = .normal,
        dateFormat: DateFormatOption = .iso8601,
        nullDisplay: String = "NULL",
        defaultPageSize: Int = 1_000,
        showAlternateRows: Bool = true,
        showRowNumbers: Bool = true,
        autoShowInspector: Bool = false,
        enableSmartValueDetection: Bool = true,
        countRowsIfEstimateLessThan: Int = 100_000,
        queryResultLimit: Int = 10_000,
        enforceQueryResultLimit: Bool = true
    ) {
        self.rowHeight = rowHeight
        self.dateFormat = dateFormat
        self.nullDisplay = nullDisplay
        self.defaultPageSize = defaultPageSize
        self.showAlternateRows = showAlternateRows
        self.showRowNumbers = showRowNumbers
        self.autoShowInspector = autoShowInspector
        self.enableSmartValueDetection = enableSmartValueDetection
        self.countRowsIfEstimateLessThan = countRowsIfEstimateLessThan
        self.queryResultLimit = queryResultLimit
        self.enforceQueryResultLimit = enforceQueryResultLimit
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
        enableSmartValueDetection = try container.decodeIfPresent(Bool.self, forKey: .enableSmartValueDetection) ?? true
        countRowsIfEstimateLessThan = try container.decodeIfPresent(Int.self, forKey: .countRowsIfEstimateLessThan) ?? 100_000
        queryResultLimit = try container.decodeIfPresent(Int.self, forKey: .queryResultLimit) ?? 10_000
        enforceQueryResultLimit = try container.decodeIfPresent(Bool.self, forKey: .enforceQueryResultLimit) ?? true
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
            return String(format: String(localized: "NULL display must be %d characters or less"), maxLength)
        } else if nullDisplay != sanitized {
            return String(localized: "NULL display contains invalid characters (newlines/tabs)")
        }
        return nil
    }

    /// Validation error for defaultPageSize (for UI feedback)
    var defaultPageSizeValidationError: String? {
        let range = SettingsValidationRules.defaultPageSizeRange
        if defaultPageSize < range.lowerBound || defaultPageSize > range.upperBound {
            return String(format: String(localized: "Page size must be between %@ and %@"), range.lowerBound.formatted(), range.upperBound.formatted())
        }
        return nil
    }

    /// Validated queryResultLimit (100 to 500,000; 0 means unlimited)
    var validatedQueryResultLimit: Int {
        if queryResultLimit == 0 { return 0 }
        return queryResultLimit.clamped(to: SettingsValidationRules.queryResultLimitRange)
    }

    /// Validation error for queryResultLimit (for UI feedback)
    var queryResultLimitValidationError: String? {
        let range = SettingsValidationRules.queryResultLimitRange
        if queryResultLimit != 0 && (queryResultLimit < range.lowerBound || queryResultLimit > range.upperBound) {
            return String(
                format: String(localized: "Query result limit must be between %@ and %@"),
                range.lowerBound.formatted(),
                range.upperBound.formatted()
            )
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
