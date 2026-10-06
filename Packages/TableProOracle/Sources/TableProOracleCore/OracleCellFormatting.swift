import Foundation
import NIOCore
import OracleNIO
import OSLog

/// Cell text built from the bytes Oracle sends, so it never depends on the session's NLS settings.
///
/// Datetimes are read field by field rather than through `Date`: a `Double` of seconds cannot hold
/// nine fractional digits, and Oracle's own calendar fields are already the text to print, including
/// years before 1582 and BC, which Foundation's calendar would move.
public enum OracleCellFormatting {
    public static let maxHexBytes = 4_096

    /// A region-named zone is sent as an id into Oracle's time zone file, which the client does not have.
    public static let timeZoneRegionPlaceholder = unsupportedPlaceholder(typeName: "time zone region")

    // MARK: - Datetimes

    /// A zone's hour and minute are each sent above a bias, so a zone west of UTC sends bytes below it.
    private static let zoneHourBias = 20
    private static let zoneMinuteBias = 60

    /// `DATE` as `YYYY-MM-DD HH:MM:SS`. Oracle's DATE always carries a time of day.
    public static func dateText(wire bytes: [UInt8]) -> String? {
        guard let fields = OracleWireDateTime(bytes) else { return nil }
        return fields.text(fractionDigits: 0)
    }

    /// `TIMESTAMP(p)`, with `.` and exactly `p` digits when `p` is above 0.
    public static func timestampText(wire bytes: [UInt8], fractionDigits: Int) -> String? {
        guard let fields = OracleWireDateTime(bytes) else { return nil }
        return fields.text(fractionDigits: fractionDigits)
    }

    /// `TIMESTAMP(p) WITH TIME ZONE` as the wall clock at the value's own offset, followed by that offset
    /// with no space. The date and time bytes are UTC.
    public static func timestampWithTimeZoneText(wire bytes: [UInt8], fractionDigits: Int) -> String? {
        guard var fields = OracleWireDateTime(bytes) else { return nil }
        guard bytes.count >= 13, bytes[11] != 0, bytes[12] != 0 else {
            return fields.text(fractionDigits: fractionDigits) + "+00:00"
        }
        if bytes[11] & 0x80 != 0 {
            return timeZoneRegionPlaceholder
        }
        let offsetMinutes = (Int(bytes[11]) - zoneHourBias) * 60 + Int(bytes[12]) - zoneMinuteBias
        fields.shift(bySeconds: offsetMinutes * 60)
        return fields.text(fractionDigits: fractionDigits) + offsetText(minutes: offsetMinutes)
    }

    /// `TIMESTAMP(p) WITH LOCAL TIME ZONE` as the session's wall clock, followed by the session's offset at that
    /// instant in the same form as a `TIMESTAMP WITH TIME ZONE`. The offset keeps the instant: a copy into a type with
    /// a zone would otherwise read the wall clock in its own zone.
    ///
    /// The bytes are the value normalized to the database time zone (measured on Oracle 23ai: the bytes do
    /// not follow the session's zone), so they are moved from that zone to the session's.
    public static func localTimestampText(
        wire bytes: [UInt8],
        fractionDigits: Int,
        zones: OracleSessionTimeZones
    ) -> String? {
        guard var fields = OracleWireDateTime(bytes) else { return nil }
        let wallSeconds = fields.secondsTreatingFieldsAsUTC
        let databaseOffset = offsetSeconds(of: zones.database, atWallClock: wallSeconds)
        let instant = wallSeconds - databaseOffset
        // Whole minutes, as the suffix can only say: a zone's local mean time before standard time has seconds.
        let sessionOffset = zones.session.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(instant))) / 60 * 60
        fields.shift(bySeconds: sessionOffset - databaseOffset)
        return fields.text(fractionDigits: fractionDigits) + offsetText(minutes: sessionOffset / 60)
    }

    /// A wall clock in a zone with daylight saving has an offset that depends on the instant, which in turn
    /// depends on the offset; one refinement settles it outside the hour a clock change skips or repeats.
    private static func offsetSeconds(of zone: TimeZone, atWallClock wallSeconds: Int) -> Int {
        let guess = zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(wallSeconds)))
        return zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(wallSeconds - guess)))
    }

    static func offsetText(minutes: Int) -> String {
        let magnitude = abs(minutes)
        return (minutes < 0 ? "-" : "+") + pad(magnitude / 60, width: 2) + ":" + pad(magnitude % 60, width: 2)
    }

    static func pad(_ value: Int, width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    // MARK: - Intervals

    public static func formatIntervalDS(
        days: Int,
        hours: Int,
        minutes: Int,
        seconds: Int,
        nanoseconds: Int
    ) -> String {
        let isNegative = days < 0 || hours < 0 || minutes < 0
            || seconds < 0 || nanoseconds < 0
        let sign = isNegative ? "-" : ""
        let base = String(
            format: "%@%d %02d:%02d:%02d",
            sign,
            abs(days),
            abs(hours),
            abs(minutes),
            abs(seconds)
        )
        let absNanos = abs(nanoseconds)
        if absNanos == 0 {
            return base
        }
        var fractional = String(format: "%09d", absNanos)
        while fractional.last == "0" {
            fractional.removeLast()
        }
        return "\(base).\(fractional)"
    }

    public static func formatIntervalYM(years: Int, months: Int) -> String {
        let isNegative = years < 0 || months < 0
        let sign = isNegative ? "-" : ""
        return String(format: "%@%d-%02d", sign, abs(years), abs(months))
    }

    // MARK: - Other values

    /// A BFILE spelled as the call that creates it, so the text names the file and can be written back.
    public static func bfileText(directory: String, fileName: String) -> String {
        "BFILENAME('\(directory.replacingOccurrences(of: "'", with: "''"))', "
            + "'\(fileName.replacingOccurrences(of: "'", with: "''"))')"
    }

    public static func hexEncode(_ bytes: [UInt8]) -> String {
        let totalBytes = bytes.count
        let limit = min(totalBytes, maxHexBytes)
        let hex = bytes.prefix(limit).map { String(format: "%02x", $0) }.joined()
        if totalBytes > limit {
            return "\(hex)… (\(totalBytes) bytes)"
        }
        return hex
    }

    public static func unsupportedPlaceholder(typeName: String) -> String {
        "<unsupported: \(typeName)>"
    }
}

/// The two zones a `TIMESTAMP WITH LOCAL TIME ZONE` moves between: the database's, which the stored value
/// is normalized to, and the session's, which it is read and written in.
public struct OracleSessionTimeZones: Sendable, Equatable {
    public let database: TimeZone
    public let session: TimeZone

    public init(database: TimeZone, session: TimeZone) {
        self.database = database
        self.session = session
    }

    /// Each zone by name, which carries daylight saving, and by its offset now, for a region name
    /// Foundation does not know.
    static let query =
        "SELECT DBTIMEZONE, SESSIONTIMEZONE, TZ_OFFSET(DBTIMEZONE), TZ_OFFSET(SESSIONTIMEZONE) FROM \(OracleDictionary.dual)"

    /// The zones the driver works in when the session's could not be read: it sets the session's zone to the Mac's
    /// at login, and a database zone of UTC is Oracle's recommendation and the common case.
    static var driverDefault: OracleSessionTimeZones {
        OracleSessionTimeZones(database: .gmt, session: .current)
    }

    /// Read from the answer to ``query``.
    init?(row: [OracleRawCell]) {
        guard row.count >= 4,
              let database = Self.zone(named: row[0].stringValue, offset: row[2].stringValue),
              let session = Self.zone(named: row[1].stringValue, offset: row[3].stringValue)
        else { return nil }
        self.init(database: database, session: session)
    }

    private static func zone(named name: String?, offset: String?) -> TimeZone? {
        if let name, let zone = zone(fromOffset: name) ?? TimeZone(identifier: name) {
            return zone
        }
        return offset.flatMap(zone(fromOffset:))
    }

    /// `+07:00`, `-05:30` and `+00:00`, as Oracle spells a zone given by offset.
    ///
    /// The text comes from the server, so the parts are range-checked before they are multiplied: a zone such as
    /// `+99999999999999999:00` overflowed the arithmetic.
    static func zone(fromOffset text: String) -> TimeZone? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.dropFirst().split(separator: ":")
        guard let sign = trimmed.first, sign == "+" || sign == "-", parts.count == 2,
              let hours = Int(parts[0]), let minutes = Int(parts[1]),
              (0 ... 18).contains(hours), (0 ... 59).contains(minutes)
        else { return nil }
        let seconds = (hours * 3_600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    /// Whether a statement can change the session's zone, so the zones read before it no longer hold.
    static func mayChange(after sql: String) -> Bool {
        var reader = HeaderReader(String(String.UnicodeScalarView(sql.unicodeScalars.prefix(4_096))))
        return reader.nextWord() == "ALTER" && reader.nextWord() == "SESSION"
    }
}

/// The seven date and time bytes of an Oracle DATE or TIMESTAMP, and the four nanosecond bytes after them.
struct OracleWireDateTime: Equatable {
    /// Oracle's numbering: the year before 1 is -1.
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int
    var nanosecond: Int

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 7 else { return nil }
        year = (Int(bytes[0]) - 100) * 100 + Int(bytes[1]) - 100
        month = Int(bytes[2])
        day = Int(bytes[3])
        hour = Int(bytes[4]) - 1
        minute = Int(bytes[5]) - 1
        second = Int(bytes[6]) - 1
        nanosecond = bytes.count >= 11 ? bytes[7 ..< 11].reduce(0) { $0 << 8 | Int($1) } : 0
    }

    /// Year, month and day in four, two and two digits, then the time, then `.` and exactly
    /// `fractionDigits` digits when that is above 0.
    func text(fractionDigits: Int) -> String {
        let pad = OracleCellFormatting.pad
        let yearText = (year < 0 ? "-" : "") + pad(abs(year), 4)
        var text = "\(yearText)-\(pad(month, 2))-\(pad(day, 2)) \(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2))"
        let digits = min(max(fractionDigits, 0), 9)
        if digits > 0 {
            text += "." + String(pad(nanosecond, 9).prefix(digits))
        }
        return text
    }

    /// Seconds since 1970 as if the fields named a UTC wall clock, in proleptic Gregorian days.
    var secondsTreatingFieldsAsUTC: Int {
        let days = Self.daysFromCivil(year: year < 0 ? year + 1 : year, month: month, day: day)
        return days * 86_400 + hour * 3_600 + minute * 60 + second
    }

    mutating func shift(bySeconds offset: Int) {
        let total = secondsTreatingFieldsAsUTC + offset
        let days = total >= 0 ? total / 86_400 : (total - 86_399) / 86_400
        let secondOfDay = total - days * 86_400
        let civil = Self.civilFromDays(days)
        year = civil.year <= 0 ? civil.year - 1 : civil.year
        month = civil.month
        day = civil.day
        hour = secondOfDay / 3_600
        minute = secondOfDay % 3_600 / 60
        second = secondOfDay % 60
    }

    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let year = month <= 2 ? year - 1 : year
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}

/// What a result column's cells need to be read as text: the type the server described, and its scale,
/// which for a TIMESTAMP is the number of fractional-second digits it holds.
struct OracleResultColumn: Sendable, Equatable {
    let name: String
    let dataType: OracleDataType
    let scale: Int

    init(name: String, dataType: OracleDataType, scale: Int) {
        self.name = name
        self.dataType = dataType
        self.scale = scale
    }

    init(_ column: OracleColumn) {
        self.init(name: column.name, dataType: column.dataType, scale: column.scale)
    }

    var descriptor: OracleColumnDescriptor {
        OracleColumnDescriptor(name: name, typeName: OracleCellDecoding.typeName(of: dataType))
    }

    /// Fractional-second digits. The describe reports them as the scale of a datetime column; anything
    /// outside 0...9 is not a datetime scale, so all nine are kept.
    var fractionDigits: Int {
        (0 ... 9).contains(scale) ? scale : 9
    }
}

/// Turns a fetched cell into the text or bytes a result carries.
enum OracleCellDecoding {
    private static let logger = Logger(subsystem: "com.TablePro", category: "OracleCellDecoding")

    /// `unsupported` hears the type name of a cell rendered as a placeholder, so the caller can log it once.
    static func decode(
        _ cell: OracleCell,
        column: OracleResultColumn,
        zones: OracleSessionTimeZones,
        unsupported: (String) -> Void
    ) -> OracleRawCell {
        guard let bytes = cell.bytes else { return .null }

        if cell.dataType == .raw || cell.dataType == .longRAW || cell.dataType == .blob {
            return .bytes(Data(bytes.readableBytesView))
        }

        do {
            guard let text = try text(of: cell, wire: Array(bytes.readableBytesView), column: column, zones: zones,
                                      unsupported: unsupported)
            else { return .null }
            return .string(text)
        } catch {
            logger.error(
                "Oracle decode failed for column '\(cell.columnName, privacy: .private(mask: .hash))': \(String(describing: type(of: error)), privacy: .public) \(String(describing: error), privacy: .private)"
            )
            return .string("<decode error>")
        }
    }

    private static func text(
        of cell: OracleCell,
        wire: [UInt8],
        column: OracleResultColumn,
        zones: OracleSessionTimeZones,
        unsupported: (String) -> Void
    ) throws -> String? {
        switch cell.dataType {
        case .varchar, .nVarchar, .char, .nChar, .long, .longNVarchar, .clob, .nCLOB, .json, .rowID, .uRowID:
            return try cell.decode(String.self)

        case .number, .binaryInteger:
            return try cell.decode(OracleNumber.self).description

        case .binaryFloat:
            return String(try cell.decode(Float.self))

        case .binaryDouble:
            return String(try cell.decode(Double.self))

        case .boolean:
            return try cell.decode(Bool.self) ? "true" : "false"

        case .date:
            return OracleCellFormatting.dateText(wire: wire)

        case .timestamp:
            return OracleCellFormatting.timestampText(wire: wire, fractionDigits: column.fractionDigits)

        case .timestampTZ:
            return OracleCellFormatting.timestampWithTimeZoneText(wire: wire, fractionDigits: column.fractionDigits)

        case .timestampLTZ:
            return OracleCellFormatting.localTimestampText(wire: wire, fractionDigits: column.fractionDigits, zones: zones)

        case .intervalDS:
            let interval = try cell.decode(IntervalDS.self)
            return OracleCellFormatting.formatIntervalDS(
                days: interval.days,
                hours: interval.hours,
                minutes: interval.minutes,
                seconds: interval.seconds,
                nanoseconds: interval.fractionalSeconds
            )

        case .intervalYM:
            let interval = try cell.decode(IntervalYM.self)
            return OracleCellFormatting.formatIntervalYM(years: interval.years, months: interval.months)

        case .bFile:
            guard let file = try? cell.decode(OracleBFile.self) else { return "<bfile>" }
            return OracleCellFormatting.bfileText(directory: file.directory, fileName: file.fileName)

        case .cursor:
            return "<cursor>"

        case .vector:
            return "<vector>"

        default:
            let name = typeName(of: cell.dataType)
            unsupported(name)
            return OracleCellFormatting.unsupportedPlaceholder(typeName: name)
        }
    }

    /// The lowercase Oracle name a result header shows for a column's described type.
    static func typeName(of dataType: OracleDataType) -> String {
        if dataType == .varchar { return "varchar2" }
        if dataType == .number { return "number" }
        if dataType == .binaryFloat { return "binary_float" }
        if dataType == .binaryDouble { return "binary_double" }
        if dataType == .date { return "date" }
        if dataType == .raw { return "raw" }
        if dataType == .longRAW { return "long raw" }
        if dataType == .char { return "char" }
        if dataType == .nChar { return "nchar" }
        if dataType == .nVarchar { return "nvarchar2" }
        if dataType == .nCLOB { return "nclob" }
        if dataType == .clob { return "clob" }
        if dataType == .blob { return "blob" }
        if dataType == .bFile { return "bfile" }
        if dataType == .timestamp { return "timestamp" }
        if dataType == .timestampTZ { return "timestamp with time zone" }
        if dataType == .timestampLTZ { return "timestamp with local time zone" }
        if dataType == .intervalDS { return "interval day to second" }
        if dataType == .intervalYM { return "interval year to month" }
        if dataType == .rowID { return "rowid" }
        if dataType == .uRowID { return "urowid" }
        if dataType == .boolean { return "boolean" }
        if dataType == .long { return "long" }
        if dataType == .json { return "json" }
        if dataType == .vector { return "vector" }
        if dataType == .binaryInteger { return "binary_integer" }
        if dataType == .object { return "object" }
        if dataType == .ref { return "ref" }
        if dataType == .cursor { return "cursor" }
        /// Only an NCLOB reaches a cell as LONG NVARCHAR, which is how the driver fetches it; Oracle has no
        /// LONG NVARCHAR column.
        if dataType == .longNVarchar { return "nclob" }
        return "unknown"
    }
}
