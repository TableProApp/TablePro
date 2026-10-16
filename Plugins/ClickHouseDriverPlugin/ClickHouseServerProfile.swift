//
//  ClickHouseServerProfile.swift
//  ClickHouseDriverPlugin
//

import Foundation
import TableProPluginKit

/// What one server accepts and holds, asked of the server at connect instead of predicted from its
/// version. `http_write_exception_in_output_format` first shipped in 23.9 and reached the 23.8 line
/// only in 23.8.9, Altinity builds carry their own numbering, and a settings profile or a
/// constraint makes a setting read-only for one user: none of that shows in the version. A setting
/// the server does not know, or will not let this user change, fails the whole request.
struct ClickHouseServerProfile: Sendable, Equatable {
    let version: ClickHouseServerVersion?
    /// The settings this user may change, each with the bounds a settings constraint puts on it.
    let settingLimits: [ClickHouseURLSetting: ClickHouseSettingLimits]
    let catalog: Set<ClickHouseCatalogFeature>

    /// Before the probes answer, a request carries nothing the server could refuse, so a
    /// `readonly = 1` user can still connect.
    static let bootstrap = ClickHouseServerProfile(
        version: nil,
        writableSettings: [],
        catalog: Set(ClickHouseCatalogFeature.allCases)
    )

    /// `system.settings` is readable by every user, grants or not, and reports per user whether
    /// a setting can be changed. Its `readonly` column arrived in 20.3, so the columns are read by
    /// name, and the user's own `readonly` setting answers for 19.16.
    static let settingsProbeQuery = """
        SELECT * FROM system.settings
        WHERE name IN (\((ClickHouseURLSetting.allCases.map(\.rawValue) + ["readonly"]).map { "'\($0)'" }.joined(separator: ", ")))
        """

    /// One row, one column per feature. `system.columns` lists nothing to a user without grants
    /// on the system database, which 25.8's shipped config requires, while `hasColumnInTable` and
    /// `system.tables` still answer.
    static let catalogProbeQuery = "SELECT " + ClickHouseCatalogFeature.allCases
        .map { "\($0.probeExpression) AS \($0.rawValue)" }
        .joined(separator: ", ")

    init(
        version: ClickHouseServerVersion?,
        settingLimits: [ClickHouseURLSetting: ClickHouseSettingLimits],
        catalog: Set<ClickHouseCatalogFeature>
    ) {
        self.version = version
        self.settingLimits = settingLimits
        self.catalog = catalog
    }

    init(
        version: ClickHouseServerVersion?,
        writableSettings: Set<ClickHouseURLSetting>,
        catalog: Set<ClickHouseCatalogFeature>
    ) {
        self.init(
            version: version,
            settingLimits: Dictionary(uniqueKeysWithValues: writableSettings.map { ($0, ClickHouseSettingLimits()) }),
            catalog: catalog
        )
    }

    /// A settings probe that could not be read sends nothing optional, which every user may do.
    /// A catalog probe that could not be read asks for everything and lets the server answer, as
    /// the driver did before it asked.
    init(
        versionText: String?,
        settings: (columns: [String], rows: [[PluginCellValue]])?,
        catalogRow: [PluginCellValue]?
    ) {
        self.init(
            version: versionText.flatMap(ClickHouseServerVersion.init),
            settingLimits: settings.map { Self.settingLimits(columns: $0.columns, rows: $0.rows) } ?? [:],
            catalog: catalogRow.map(Self.catalog(row:)) ?? Set(ClickHouseCatalogFeature.allCases)
        )
    }

    var writableSettings: Set<ClickHouseURLSetting> { Set(settingLimits.keys) }

    /// The URL item for `value`, or nil when this user may not set it to that.
    func queryItem(_ setting: ClickHouseURLSetting, _ value: String) -> URLQueryItem? {
        guard settingLimits[setting]?.allows(value) == true else { return nil }
        return URLQueryItem(name: setting.rawValue, value: value)
    }


    var hasDataSkippingIndices: Bool { catalog.contains(.dataSkippingIndices) }
    var hasTableComments: Bool { catalog.contains(.tablesComment) }
    var hasViewSelectText: Bool { catalog.contains(.tablesAsSelect) }
    var hasTableTotals: Bool { catalog.isSuperset(of: [.tablesTotalRows, .tablesTotalBytes]) }
    var hasFunctionOrigin: Bool { catalog.contains(.functionsOrigin) }
    var hasFunctionCreateQuery: Bool { catalog.contains(.functionsCreateQuery) }

    /// The statement parses from 21.11 but does nothing on ReplicatedMergeTree before 23.9 while
    /// reporting success (ClickHouse#51304), so it is offered from 23.9. No catalog says so.
    var hasModifyComment: Bool { version?.isAtLeast(major: 23, minor: 9) ?? false }

    static func writableSettings(columns: [String], rows: [[PluginCellValue]]) -> Set<ClickHouseURLSetting> {
        Set(settingLimits(columns: columns, rows: rows).keys)
    }

    static func settingLimits(
        columns: [String],
        rows: [[PluginCellValue]]
    ) -> [ClickHouseURLSetting: ClickHouseSettingLimits] {
        guard let nameIndex = columns.firstIndex(of: "name") else { return [:] }
        /// `readonly = 1` forbids changing any setting; 2 still allows it.
        if let valueIndex = columns.firstIndex(of: "value"),
           rows.contains(where: { $0[safe: nameIndex]?.asText == "readonly" && $0[safe: valueIndex]?.asText == "1" }) {
            return [:]
        }
        let readonlyIndex = columns.firstIndex(of: "readonly")
        let cell = { (row: [PluginCellValue], column: String) -> String? in
            columns.firstIndex(of: column).flatMap { row[safe: $0]?.asText }
        }
        var limits: [ClickHouseURLSetting: ClickHouseSettingLimits] = [:]
        for row in rows {
            guard let setting = row[safe: nameIndex]?.asText.flatMap(ClickHouseURLSetting.init(rawValue:)) else {
                continue
            }
            if let readonlyIndex, row[safe: readonlyIndex]?.asText != "0" { continue }
            limits[setting] = ClickHouseSettingLimits(
                min: cell(row, "min"),
                max: cell(row, "max"),
                disallowedValues: cell(row, "disallowed_values")
            )
        }
        return limits
    }

    static func catalog(row: [PluginCellValue]) -> Set<ClickHouseCatalogFeature> {
        Set(ClickHouseCatalogFeature.allCases.enumerated().compactMap { index, feature in
            let count = row[safe: index]?.asText.flatMap { Int($0) } ?? 0
            return count > 0 ? feature : nil
        })
    }
}

/// The bounds a settings constraint puts on one setting (`system.settings` `min`, `max` and,
/// from 25.x, `disallowed_values`). A writable setting can still refuse a value outside them.
struct ClickHouseSettingLimits: Sendable, Equatable {
    var min: Double?
    var max: Double?
    var disallowed: [String] = []

    init(min: Double? = nil, max: Double? = nil, disallowed: [String] = []) {
        self.min = min
        self.max = max
        self.disallowed = disallowed
    }

    init(min: String?, max: String?, disallowedValues: String?) {
        self.init(
            min: Self.number(min),
            max: Self.number(max),
            disallowed: Self.arrayItems(disallowedValues)
        )
    }

    func allows(_ value: String) -> Bool {
        let number = Self.number(value)
        let isDisallowed = disallowed.contains { item in
            item == value || (number != nil && Self.number(item) == number)
        }
        guard !isDisallowed else { return false }
        guard let number else { return true }
        if let min, number < min { return false }
        if let max, number > max { return false }
        return true
    }

    private static func number(_ text: String?) -> Double? {
        switch text {
        case "true": 1
        case "false": 0
        default: text.flatMap(Double.init)
        }
    }

    /// `['break', 'throw']` as TabSeparated writes an `Array(String)`.
    private static func arrayItems(_ text: String?) -> [String] {
        guard let text, text.hasPrefix("["), text.hasSuffix("]") else { return [] }
        return text.dropFirst().dropLast()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '")) }
            .filter { !$0.isEmpty }
    }
}

/// The URL settings the driver sends only when the server lets this user change them.
/// `max_execution_time` is not here: `applyQueryTimeout` sends it once and keeps it only when the
/// server accepts it.
enum ClickHouseURLSetting: String, CaseIterable, Sendable {
    case sendProgressInHTTPHeaders = "send_progress_in_http_headers"
    case httpWriteExceptionInOutputFormat = "http_write_exception_in_output_format"
    case maxResultRows = "max_result_rows"
    case resultOverflowMode = "result_overflow_mode"
    case cancelHTTPReadonlyQueriesOnClientClose = "cancel_http_readonly_queries_on_client_close"
}

/// System catalog parts the metadata reads use that older servers lack, measured: 19.16 and 20.3
/// have no `system.tables.total_rows` or `total_bytes`, 21.3 no `system.tables.comment`, 21.8 no
/// `as_select`, 21.10 no `system.functions.origin`, and `system.data_skipping_indices` first
/// ships in 21.8. On 25.8's shipped config a user without system grants cannot read the
/// skipping-index table, and `system.tables` does not list it to them either.
enum ClickHouseCatalogFeature: String, CaseIterable, Sendable {
    case tablesComment = "tables_comment"
    case tablesAsSelect = "tables_as_select"
    case tablesTotalRows = "tables_total_rows"
    case tablesTotalBytes = "tables_total_bytes"
    case functionsOrigin = "functions_origin"
    case functionsCreateQuery = "functions_create_query"
    case dataSkippingIndices = "data_skipping_indices"

    /// `hasColumnInTable` on a table the server lacks throws, so the skipping-index table is
    /// looked up in `system.tables` instead.
    var probeExpression: String {
        switch self {
        case .tablesComment: "hasColumnInTable('system', 'tables', 'comment')"
        case .tablesAsSelect: "hasColumnInTable('system', 'tables', 'as_select')"
        case .tablesTotalRows: "hasColumnInTable('system', 'tables', 'total_rows')"
        case .tablesTotalBytes: "hasColumnInTable('system', 'tables', 'total_bytes')"
        case .functionsOrigin: "hasColumnInTable('system', 'functions', 'origin')"
        case .functionsCreateQuery: "hasColumnInTable('system', 'functions', 'create_query')"
        case .dataSkippingIndices:
            "(SELECT count() FROM system.tables WHERE database = 'system' AND name = 'data_skipping_indices')"
        }
    }
}

/// `version()` is four numbers on official and Cloud builds, and Altinity appends a fifth,
/// non-numeric part (`24.8.14.10548.altinitystable`).
struct ClickHouseServerVersion: Sendable, Equatable {
    let components: [Int]

    init?(_ text: String) {
        let numbers = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".")
            .prefix { Int($0) != nil }
            .compactMap { Int($0) }
        guard !numbers.isEmpty else { return nil }
        components = Array(numbers.prefix(4))
    }

    func isAtLeast(major: Int, minor: Int) -> Bool {
        let own = (components[0], components.count > 1 ? components[1] : 0)
        return own >= (major, minor)
    }
}
