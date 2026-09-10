//
//  DateFormatOption.swift
//  TablePro
//

import Foundation

/// The date patterns the grid can render a database date in.
///
/// This is the formatting layer's own vocabulary, not a settings type. `DataGridSettings` persists
/// a value of it, which is a reference in the right direction: declaring it in the settings model
/// instead put every date formatter's compile closure through `AppSettings`, and from there through
/// storage, the keychain and the plugin registry.
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

    var dateOnlyFormatString: String {
        switch self {
        case .iso8601, .iso8601Date: return "yyyy-MM-dd"
        case .usLong, .usShort: return "MM/dd/yyyy"
        case .euLong, .euShort: return "dd/MM/yyyy"
        }
    }

    var timeOnlyFormatString: String {
        switch self {
        case .usLong: return "hh:mm:ss a"
        default: return "HH:mm:ss"
        }
    }
}
