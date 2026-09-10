//
//  SnowflakeValueDecoder.swift
//  SnowflakeDriverPlugin
//
//  Turns the internal encodings the query-request endpoint puts in `rowset` into the conventional
//  text the rest of TablePro reads. The endpoint sends every cell as a JSON string carrying
//  Snowflake's own representation, so the column's `rowtype` entry is the only thing that says what
//  a string means: "20682" is a DATE's epoch day, a NUMBER's value, or a piece of text, and nothing
//  in the string itself distinguishes them. Decoding is therefore keyed on the column, never on the
//  value, and a value the column's encoding cannot explain is returned exactly as it arrived.
//

import Foundation

enum SnowflakeValueDecoder {
    static func decode(_ raw: String, as column: SnowflakeColumnMeta) -> PluginCellValueBox {
        guard let type = SnowflakeLogicalType(internalType: column.internalType) else {
            return .text(raw)
        }
        switch type {
        case .date:
            return date(fromEpochDays: raw)
        case .time:
            return time(fromSecondsSinceMidnight: raw, scale: column.scale)
        case .timestampNtz:
            return timestamp(fromEpochSeconds: raw, scale: column.scale, zone: .none)
        case .timestampLtz:
            return timestamp(fromEpochSeconds: raw, scale: column.scale, zone: .utc)
        case .timestampTz:
            return timestampWithZone(raw, scale: column.scale)
        case .binary:
            return binary(raw)
        case .fixed, .real, .text, .boolean, .variant, .object, .array, .geography, .geometry:
            return .text(raw)
        }
    }

    // MARK: - Temporal

    private static func date(fromEpochDays raw: String) -> PluginCellValueBox {
        guard let days = Int(raw), let civil = CivilDate(epochDays: days) else { return .text(raw) }
        return .text(civil.text)
    }

    private static func time(fromSecondsSinceMidnight raw: String, scale: Int?) -> PluginCellValueBox {
        guard let parts = FixedPointSeconds(raw),
              parts.seconds >= 0, parts.seconds < secondsPerDay
        else { return .text(raw) }
        return .text(ClockTime(secondOfDay: parts.seconds).text + parts.fractionText(scale: scale))
    }

    private static func timestamp(
        fromEpochSeconds raw: String,
        scale: Int?,
        zone: ZoneRendering
    ) -> PluginCellValueBox {
        guard let parts = FixedPointSeconds(raw),
              let (date, clock) = civil(epochSeconds: parts.seconds, offsetMinutes: zone.offsetMinutes)
        else { return .text(raw) }
        return .text(date + " " + clock + parts.fractionText(scale: scale) + zone.suffix)
    }

    /// `TIMESTAMP_TZ` is the epoch seconds, a space, and the zone offset in minutes biased by +1440
    /// so it never needs a sign. Snowflake's own example is `1616173619.000000000 1500`, where 1500
    /// means UTC+1.
    private static func timestampWithZone(_ raw: String, scale: Int?) -> PluginCellValueBox {
        let fields = raw.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 2, let biased = Int(fields[1]) else { return .text(raw) }
        let offsetMinutes = biased - offsetBias
        guard abs(offsetMinutes) <= maximumOffsetMinutes else { return .text(raw) }
        return timestamp(
            fromEpochSeconds: String(fields[0]),
            scale: scale,
            zone: .offset(minutes: offsetMinutes)
        )
    }

    private static func civil(epochSeconds: Int, offsetMinutes: Int) -> (date: String, clock: String)? {
        let (shifted, overflow) = epochSeconds.addingReportingOverflow(offsetMinutes * 60)
        guard !overflow else { return nil }
        let days = Int((Double(shifted) / Double(secondsPerDay)).rounded(.down))
        guard let civil = CivilDate(epochDays: days) else { return nil }
        return (civil.text, ClockTime(secondOfDay: shifted - days * secondsPerDay).text)
    }

    // MARK: - Binary

    /// Snowflake writes `BINARY` as a hex string. Handing the app the bytes rather than the hex is
    /// what keeps the grid, the hex editor and every export reading one representation: a `BINARY`
    /// column is classified as a blob, and a blob cell holding text is rendered as the hex of that
    /// text, so the hex arrives on screen hexed a second time.
    private static func binary(_ raw: String) -> PluginCellValueBox {
        let digits = Array(raw.utf8)
        guard digits.count.isMultiple(of: 2) else { return .text(raw) }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else {
                return .text(raw)
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        return .bytes(Data(bytes))
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    // MARK: - Constants

    private static let secondsPerDay = 86_400
    private static let offsetBias = 1_440

    /// `TimeZone(secondsFromGMT:)` returns nil beyond eighteen hours, and `DatabaseDateParser` reads
    /// that nil as GMT, so a `+18:30` suffix would come back as an instant eighteen and a half hours
    /// from the one Snowflake sent. A payload that cannot survive the round trip keeps its raw text
    /// instead of being written in a spelling the reader will misread.
    private static let maximumOffsetMinutes = 1_080
}

/// How a decoded timestamp names the zone it was read in. `TIMESTAMP_NTZ` genuinely has none, so it
/// stays a bare wall clock; `TIMESTAMP_LTZ` is an absolute instant stored in UTC, and leaving it
/// unmarked would let the reader's own zone be applied to a UTC wall clock and move the instant.
private enum ZoneRendering {
    case none
    case utc
    case offset(minutes: Int)

    var offsetMinutes: Int {
        switch self {
        case .none, .utc: return 0
        case .offset(let minutes): return minutes
        }
    }

    var suffix: String {
        switch self {
        case .none: return ""
        case .utc: return "Z"
        case .offset(let minutes):
            let magnitude = abs(minutes)
            return String(format: "%@%02d:%02d", minutes < 0 ? "-" : "+", magnitude / 60, magnitude % 60)
        }
    }
}

/// A fixed-point seconds field split into a whole second and the nanoseconds after it.
///
/// Two things make this more than a `Double` parse. The endpoint writes nine decimal places, so
/// `1616173619.123456789` carries nineteen significant digits where a `Double` holds about
/// seventeen, and the last nanoseconds would be lost. And a value before the epoch is written as
/// the negated magnitude rather than as a floored second with a positive remainder: Snowflake's own
/// connector documents `-0.000000009` as meaning `1969-12-31 23:59:59.999999991`, so the fraction is
/// subtracted from the whole part, never added to it. Reading the sign off the integer half alone
/// loses it entirely, because `-0` parses to `0`.
private struct FixedPointSeconds {
    /// The whole second at or below the value, so the nanoseconds are always a positive offset from
    /// it and rendering never has to think about the sign again.
    let seconds: Int
    private let nanoseconds: Int

    init?(_ raw: String) {
        let isNegative = raw.hasPrefix("-")
        let separator = raw.firstIndex(of: ".")
        let wholePart = separator.map { raw[..<$0] } ?? raw[...]
        let digits = separator.map { raw[raw.index(after: $0)...] } ?? ""

        guard let whole = Int(wholePart), separator == nil || !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }), digits.count <= 9
        else { return nil }

        guard let fraction = Int(digits + String(repeating: "0", count: 9 - digits.count)) else {
            return nil
        }

        if isNegative, fraction > 0 {
            seconds = whole - 1
            nanoseconds = FixedPointSeconds.nanosecondsPerSecond - fraction
        } else {
            seconds = whole
            nanoseconds = fraction
        }
    }

    /// A column declares how many fractional digits it keeps and the wire always sends nine, so the
    /// spelling follows the column rather than the padding.
    func fractionText(scale: Int?) -> String {
        let places = min(max(scale ?? 9, 0), 9)
        guard places > 0 else { return "" }
        let digits = String(format: "%09d", nanoseconds)
        return "." + digits.prefix(places)
    }

    private static let nanosecondsPerSecond = 1_000_000_000
}

/// A date in the proleptic Gregorian calendar, which is the calendar Snowflake documents: "Snowflake
/// does not adjust dates prior to 1582 (or calculations involving dates prior to 1582) to match the
/// Julian Calendar."
///
/// Foundation cannot express that. `Calendar(identifier: .gregorian)` and `Calendar(identifier:
/// .iso8601)` both switch to the Julian calendar before 1582-10-15, and `ISO8601DateFormatter` and
/// `Date.FormatStyle.iso8601` inherit it, so all of them render epoch day -719162 as 0001-01-03
/// where Snowflake means 0001-01-01. The conversion is therefore integer arithmetic, which is exact
/// for every day in the range and needs no time zone to be right.
private struct CivilDate {
    let year: Int
    let month: Int
    let day: Int

    init?(epochDays: Int) {
        guard (CivilDate.minEpochDay ... CivilDate.maxEpochDay).contains(epochDays) else { return nil }
        var shifted = epochDays + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        shifted -= era * 146_097
        let yearOfEra = (shifted - shifted / 1_460 + shifted / 36_524 - shifted / 146_096) / 365
        let dayOfYear = shifted - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    }

    var text: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// 0001-01-01 and 9999-12-31, the range Snowflake's date and timestamp types cover. A value
    /// outside it is not a date TablePro can show, so the caller keeps the raw text instead.
    static let minEpochDay = -719_162
    static let maxEpochDay = 2_932_896
}

private struct ClockTime {
    let hour: Int
    let minute: Int
    let second: Int

    init(secondOfDay: Int) {
        hour = secondOfDay / 3_600
        minute = (secondOfDay % 3_600) / 60
        second = secondOfDay % 60
    }

    var text: String { String(format: "%02d:%02d:%02d", hour, minute, second) }
}
