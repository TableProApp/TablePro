import Foundation
import SwiftUI

enum AppAppearanceMode: String, Codable, CaseIterable {
    case light
    case dark
    case auto
}

// The appearance mode is not here: it is per Mac (`AppSettingsManager.appearanceMode`), and this
// struct is the synced `appearance` category.
struct AppearanceSettings: Codable, Equatable {
    var preferredLightThemeId: String
    var preferredDarkThemeId: String

    static let `default` = AppearanceSettings(
        preferredLightThemeId: BuiltInThemes.defaultLightId,
        preferredDarkThemeId: BuiltInThemes.defaultDarkId
    )

    init(
        preferredLightThemeId: String = BuiltInThemes.defaultLightId,
        preferredDarkThemeId: String = BuiltInThemes.defaultDarkId
    ) {
        self.preferredLightThemeId = preferredLightThemeId
        self.preferredDarkThemeId = preferredDarkThemeId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        preferredLightThemeId = container.decodeSetting(.preferredLightThemeId, default: fallback.preferredLightThemeId)
        preferredDarkThemeId = container.decodeSetting(.preferredDarkThemeId, default: fallback.preferredDarkThemeId)
    }

    private enum CodingKeys: String, CodingKey {
        case preferredLightThemeId, preferredDarkThemeId
    }
}

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

enum DefaultSortBehavior: String, Codable, CaseIterable, Identifiable, Equatable {
    case none
    case primaryKey
    case firstColumn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return String(localized: "No sorting (engine order)")
        case .primaryKey: return String(localized: "Primary key")
        case .firstColumn: return String(localized: "First column")
        }
    }
}

// IN Clause, INSERT and UPDATE are left out: they need a column or a single table, so no grid can always produce them.
enum RowCopyFormat: String, Codable, CaseIterable, Identifiable {
    case rows
    case rowsWithHeaders
    case json
    case csv
    case csvWithHeaders
    case markdown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rows: return "TSV"
        case .rowsWithHeaders: return String(localized: "TSV with Headers")
        case .json: return "JSON"
        case .csv: return "CSV"
        case .csvWithHeaders: return String(localized: "CSV with Headers")
        case .markdown: return "Markdown"
        }
    }
}

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
    var queryResultRowCap: Int
    var truncateQueryResults: Bool
    var defaultSortBehavior: DefaultSortBehavior
    var defaultSortDirection: SortDirection
    var rowCopyFormat: RowCopyFormat
    var showInvisibleCharacters: Bool
    // What a new tab's grid starts with; an open tab keeps its own choice.
    var wrapText: Bool
    // 0 keeps every result a run returns.
    var resultSetsKeptPerRun: Int

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
        queryResultRowCap: 10_000,
        truncateQueryResults: true,
        defaultSortBehavior: .primaryKey,
        defaultSortDirection: .ascending,
        rowCopyFormat: .rows,
        showInvisibleCharacters: true,
        wrapText: false,
        resultSetsKeptPerRun: 0
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
        queryResultRowCap: Int = 10_000,
        truncateQueryResults: Bool = true,
        defaultSortBehavior: DefaultSortBehavior = .primaryKey,
        defaultSortDirection: SortDirection = .ascending,
        rowCopyFormat: RowCopyFormat = .rows,
        showInvisibleCharacters: Bool = true,
        wrapText: Bool = false,
        resultSetsKeptPerRun: Int = 0
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
        self.queryResultRowCap = queryResultRowCap
        self.truncateQueryResults = truncateQueryResults
        self.defaultSortBehavior = defaultSortBehavior
        self.defaultSortDirection = defaultSortDirection
        self.rowCopyFormat = rowCopyFormat
        self.showInvisibleCharacters = showInvisibleCharacters
        self.wrapText = wrapText
        self.resultSetsKeptPerRun = resultSetsKeptPerRun
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        rowHeight = container.decodeSetting(.rowHeight, default: fallback.rowHeight)
        dateFormat = container.decodeSetting(.dateFormat, default: fallback.dateFormat)
        nullDisplay = container.decodeSetting(.nullDisplay, default: fallback.nullDisplay)
        defaultPageSize = container.decodeSetting(.defaultPageSize, default: fallback.defaultPageSize)
            .clamped(to: SettingsValidationRules.defaultPageSizeRange)
        showAlternateRows = container.decodeSetting(.showAlternateRows, default: fallback.showAlternateRows)
        showRowNumbers = container.decodeSetting(.showRowNumbers, default: fallback.showRowNumbers)
        autoShowInspector = container.decodeSetting(.autoShowInspector, default: fallback.autoShowInspector)
        enableSmartValueDetection = container.decodeSetting(
            .enableSmartValueDetection, default: fallback.enableSmartValueDetection
        )
        countRowsIfEstimateLessThan = container.decodeSetting(
            .countRowsIfEstimateLessThan, default: fallback.countRowsIfEstimateLessThan
        )
        queryResultRowCap = container.decodeSetting(.queryResultRowCap, default: fallback.queryResultRowCap)
        truncateQueryResults = container.decodeSetting(.truncateQueryResults, default: fallback.truncateQueryResults)
        defaultSortBehavior = container.decodeSetting(.defaultSortBehavior, default: fallback.defaultSortBehavior)
        defaultSortDirection = container.decodeSetting(.defaultSortDirection, default: fallback.defaultSortDirection)
        rowCopyFormat = container.decodeSetting(.rowCopyFormat, default: fallback.rowCopyFormat)
        showInvisibleCharacters = container.decodeSetting(
            .showInvisibleCharacters, default: fallback.showInvisibleCharacters
        )
        wrapText = container.decodeSetting(.wrapText, default: fallback.wrapText)
        resultSetsKeptPerRun = container.decodeSetting(.resultSetsKeptPerRun, default: fallback.resultSetsKeptPerRun)
    }

    var validatedNullDisplay: String {
        Self.normalizedNullDisplay(nullDisplay)
    }

    var validatedDefaultPageSize: Int {
        defaultPageSize.clamped(to: SettingsValidationRules.defaultPageSizeRange)
    }

    // Blank is not an error: the field's prompt reads NULL, and a blank entry commits as NULL.
    static func nullDisplayValidationError(for text: String) -> String? {
        let maxLength = SettingsValidationRules.nullDisplayMaxLength
        guard text.sanitized.count > maxLength else { return nil }
        return String(format: String(localized: "Up to %lld characters"), maxLength)
    }

    // Trimmed again after the cut, so a prefix that ends in a space never stores one.
    static func normalizedNullDisplay(_ text: String) -> String {
        let limited = String(text.sanitized.prefix(SettingsValidationRules.nullDisplayMaxLength))
            .trimmingCharacters(in: .whitespaces)
        return limited.isEmpty ? "NULL" : limited
    }

    // Nil keeps every result.
    var resultSetLimitPerRun: Int? {
        resultSetsKeptPerRun > 0 ? resultSetsKeptPerRun : nil
    }

    var validatedQueryResultRowCap: Int {
        if queryResultRowCap == 0 { return 0 }
        return queryResultRowCap.clamped(to: SettingsValidationRules.queryResultRowCapRange)
    }

    var queryResultLimit: Int? {
        guard truncateQueryResults else { return nil }
        let cap = validatedQueryResultRowCap
        return cap > 0 ? cap : nil
    }

    // No limit keeps the stored cap, so turning the limit back on returns to it.
    func withQueryResultLimit(_ limit: Int?) -> DataGridSettings {
        var updated = self
        if let limit {
            updated.truncateQueryResults = true
            updated.queryResultRowCap = limit
        } else {
            updated.truncateQueryResults = false
        }
        return updated
    }
}

struct ValueColorSettings: Codable, Equatable {
    var colorsValuesByType: Bool

    static let `default` = ValueColorSettings()

    init(colorsValuesByType: Bool = false) {
        self.colorsValuesByType = colorsValuesByType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        colorsValuesByType = container.decodeSetting(.colorsValuesByType, default: Self.default.colorsValuesByType)
    }
}

struct HistorySettings: Codable, Equatable {
    var maxEntries: Int // 0 = unlimited
    var maxDays: Int // 0 = unlimited
    var autoCleanup: Bool

    // The only setting that governs storing real row values on disk, so it is a switch rather than an assumption.
    var keepRewindHistory: Bool

    static let `default` = HistorySettings(
        maxEntries: 10_000,
        maxDays: 90,
        autoCleanup: true
    )

    init(maxEntries: Int = 10_000, maxDays: Int = 90, autoCleanup: Bool = true, keepRewindHistory: Bool = true) {
        self.maxEntries = maxEntries
        self.maxDays = maxDays
        self.autoCleanup = autoCleanup
        self.keepRewindHistory = keepRewindHistory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        maxEntries = container.decodeSetting(.maxEntries, default: fallback.maxEntries)
        maxDays = container.decodeSetting(.maxDays, default: fallback.maxDays)
        autoCleanup = container.decodeSetting(.autoCleanup, default: fallback.autoCleanup)
        keepRewindHistory = container.decodeSetting(.keepRewindHistory, default: fallback.keepRewindHistory)
    }

    var validatedMaxEntries: Int {
        max(0, maxEntries)
    }

    var validatedMaxDays: Int {
        max(0, maxDays)
    }
}

struct TabSettings: Codable, Equatable {
    var enablePreviewTabs: Bool = true
    static let `default` = TabSettings()

    init(enablePreviewTabs: Bool = true) {
        self.enablePreviewTabs = enablePreviewTabs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        enablePreviewTabs = container.decodeSetting(.enablePreviewTabs, default: fallback.enablePreviewTabs)
    }
}
