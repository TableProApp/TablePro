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

    /// The slot a value's own fractional seconds are spliced into after formatting.
    ///
    /// A control character, because it has to survive `DateFormatter` as a quoted literal and then
    /// be found again in text a database supplied. `DateFormatter` cannot render the digits itself:
    /// measured, it keeps three significant places and zero-pads the rest, so `SSSSSS` turns
    /// `.789012` into `.789000`, and `Date`'s own resolution at 2024 is about 119ns anyway.
    static let fractionalSecondsMarker: Character = "\u{1}"

    func formatString(for components: TemporalComponents) -> String {
        switch components {
        case .dateOnly: return dateOnlyFormatString
        case .timeOnly: return timeOnlyFormatString
        case .dateAndTime: return rawValue
        }
    }

    /// The same pattern with the marker quoted in immediately after the seconds, or nil for a
    /// rendering that carries no clock.
    ///
    /// The slot is placed by the pattern rather than by appending, because a fraction qualifies the
    /// seconds and only the ISO patterns end there: `MM/dd/yyyy hh:mm:ss a` has to read
    /// `11:59:59.123456 PM`, not `11:59:59 PM.123456`. It is derived from the pattern instead of
    /// spelled out per case, so a seventh option cannot place it wrong.
    func fractionalSecondsFormatString(for components: TemporalComponents) -> String? {
        let pattern = formatString(for: components)
        guard rendersTime(for: components),
              let seconds = pattern.range(of: "ss", options: .backwards)
        else {
            return nil
        }
        return pattern.replacingCharacters(in: seconds, with: "ss'\(Self.fractionalSecondsMarker)'")
    }

    /// Whether the text this option produces for a column shape carries a clock, which is what
    /// decides whether a UTC offset belongs on it: an offset qualifies a time and says nothing
    /// about a bare date.
    ///
    /// Only the date-and-time shape depends on the option, and it is switched exhaustively rather
    /// than defaulted, so a seventh pattern has to state which it is instead of silently picking.
    func rendersTime(for components: TemporalComponents) -> Bool {
        switch components {
        case .dateOnly:
            return false
        case .timeOnly:
            return true
        case .dateAndTime:
            switch self {
            case .iso8601, .usLong, .euLong: return true
            case .iso8601Date, .usShort, .euShort: return false
            }
        }
    }

    private var dateOnlyFormatString: String {
        switch self {
        case .iso8601, .iso8601Date: return "yyyy-MM-dd"
        case .usLong, .usShort: return "MM/dd/yyyy"
        case .euLong, .euShort: return "dd/MM/yyyy"
        }
    }

    private var timeOnlyFormatString: String {
        switch self {
        case .usLong: return "hh:mm:ss a"
        default: return "HH:mm:ss"
        }
    }
}
