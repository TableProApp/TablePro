//
//  ObjectListingPresentation.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// How the Objects list reads one column's values.
internal enum ObjectListingValueFormat: Equatable, Sendable {
    case text
    /// A count, such as a table's estimated rows.
    case count
    /// A size. A number is bytes; text a plugin formatted itself ("16 kB") shows as it came.
    case bytes
    /// A timestamp, shown in one fixed shape so every row lines up.
    case date

    /// Numbers line up on their last digit, the way a file size column does.
    var alignsTrailing: Bool {
        self == .count || self == .bytes
    }
}

/// What a cell sorts by, so 9 sorts before 10 and an empty cell sorts before every value.
internal enum ObjectListingSortKey: Comparable, Sendable {
    case missing
    case number(Double)
    case text(String)

    static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.missing, .missing): return false
        case (.missing, _): return true
        case (_, .missing): return false
        case (.number(let left), .number(let right)): return left < right
        case (.number, .text): return true
        case (.text, .number): return false
        case (.text(let left), .text(let right)): return left.localizedStandardCompare(right) == .orderedAscending
        }
    }
}

/// Turns listing values into the text the Objects list draws and the keys it sorts by.
///
/// Built once per listing: a byte count formatter is slow to make, and a listing formats every cell.
internal struct ObjectListingValueFormatter {
    private let locale: Locale
    private let timeZone: TimeZone
    private let byteCounter: ByteCountFormatter

    init(locale: Locale = .current, timeZone: TimeZone = .current) {
        self.locale = locale
        self.timeZone = timeZone
        byteCounter = ByteCountFormatter()
        // Binary units: InnoDB stores 16 KiB pages, so 163,840 bytes reads 160 KB rather than 164 KB.
        byteCounter.countStyle = .binary
        byteCounter.allowsNonnumericFormatting = false
    }

    func display(_ value: PluginCellValue, as format: ObjectListingValueFormat) -> String {
        guard let text = value.asText else { return "" }
        switch format {
        case .text:
            return text
        case .count:
            guard let number = Self.number(in: text) else { return text }
            if let whole = Int64(exactly: number) {
                return whole.formatted(.number.grouping(.automatic).locale(locale))
            }
            return number.formatted(.number.locale(locale))
        case .bytes:
            guard let number = Self.number(in: text), number >= 0, let bytes = Int64(exactly: number.rounded()) else {
                return text
            }
            return byteCounter.string(fromByteCount: bytes)
        case .date:
            guard let timestamp = ObjectListingTimestamp(parsing: text) else { return text }
            return timestamp.display(in: timeZone)
        }
    }

    func sortKey(_ value: PluginCellValue, as format: ObjectListingValueFormat) -> ObjectListingSortKey {
        guard let text = value.asText, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return .missing }
        switch format {
        case .text:
            return .text(text)
        case .count:
            return Self.number(in: text).map(ObjectListingSortKey.number) ?? .text(text)
        case .bytes:
            return (Self.number(in: text) ?? Self.pluginSizeBytes(in: text)).map(ObjectListingSortKey.number) ?? .text(text)
        case .date:
            return ObjectListingTimestamp(parsing: text).map { .number($0.sortValue) } ?? .text(text)
        }
    }

    /// Plain decimal digits only. `Double(_:)` alone also reads "nan", "inf" and hex floats, which no
    /// count or size is.
    static func number(in text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var digits = 0
        var dots = 0
        for (offset, character) in trimmed.enumerated() {
            if character.isASCII, character.isNumber {
                digits += 1
            } else if character == "." {
                dots += 1
            } else if character == "-", offset == 0 {
                continue
            } else {
                return nil
            }
        }
        guard digits > 0, dots <= 1 else { return nil }
        return Double(trimmed)
    }

    /// A size a plugin already formatted, such as PostgreSQL's `pg_size_pretty` "16 kB" or "0.05 MB",
    /// read back to bytes so the column still sorts by size. Those spellings count in 1,024s.
    static func pluginSizeBytes(in text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, let number = number(in: String(parts[0])) else { return nil }
        let units = ["bytes", "b", "kb", "mb", "gb", "tb", "pb"]
        guard let index = units.firstIndex(of: parts[1].lowercased()) else { return nil }
        return number * pow(1_024, Double(max(index - 1, 0)))
    }
}

/// A catalog timestamp: MySQL's `2026-08-12 08:05:33`, with a fraction or an offset where an engine adds one.
///
/// One without an offset is the server's wall clock, and the client cannot know the server's zone,
/// so it shows as written. One with an offset is an instant and shows in the reader's zone.
internal struct ObjectListingTimestamp: Equatable {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int
    /// Seconds east of UTC, nil when the text names no zone.
    let offset: Int?

    init?(parsing text: String) {
        var scanner = TimestampScanner(Array(text.trimmingCharacters(in: .whitespaces).utf8))
        guard let year = scanner.digits(4), scanner.take("-"),
              let month = scanner.digits(2), scanner.take("-"),
              let day = scanner.digits(2), scanner.take(" ") || scanner.take("T"),
              let hour = scanner.digits(2), scanner.take(":"),
              let minute = scanner.digits(2)
        else { return nil }
        var second = 0
        if scanner.take(":") {
            guard let seconds = scanner.digits(2) else { return nil }
            second = seconds
            if scanner.take(".") {
                guard scanner.skipDigits() > 0 else { return nil }
            }
        }
        scanner.skipSpaces()
        var offset: Int?
        if scanner.take("Z") {
            offset = 0
        } else if let sign = scanner.sign() {
            guard let hours = scanner.digits(2) else { return nil }
            _ = scanner.take(":")
            let minutes = scanner.digits(2) ?? 0
            offset = sign * (hours * 3_600 + minutes * 60)
        }
        guard scanner.isAtEnd, (1 ... 12).contains(month), (1 ... 31).contains(day),
              hour < 24, minute < 60, second < 61
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.offset = offset
    }

    private init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        offset = nil
    }

    func display(in zone: TimeZone) -> String {
        let shown = offset == nil ? self : wallClock(in: zone) ?? self
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            shown.year, shown.month, shown.day, shown.hour, shown.minute, shown.second
        )
    }

    /// Wall clocks compare as if they shared one zone, which they do on one server.
    var sortValue: Double {
        guard let date = Self.utcCalendar.date(from: components) else { return 0 }
        return date.timeIntervalSince1970 - Double(offset ?? 0)
    }

    private var components: DateComponents {
        DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    private func wallClock(in zone: TimeZone) -> ObjectListingTimestamp? {
        guard let utc = Self.utcCalendar.date(from: components) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let local = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: utc.addingTimeInterval(-Double(offset ?? 0))
        )
        guard let year = local.year, let month = local.month, let day = local.day,
              let hour = local.hour, let minute = local.minute, let second = local.second
        else { return nil }
        return ObjectListingTimestamp(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }
}

private struct TimestampScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool {
        index == bytes.count
    }

    mutating func digits(_ count: Int) -> Int? {
        guard index + count <= bytes.count else { return nil }
        var value = 0
        for byte in bytes[index ..< index + count] {
            guard (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        index += count
        return value
    }

    mutating func skipDigits() -> Int {
        let start = index
        while index < bytes.count, (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(bytes[index]) {
            index += 1
        }
        return index - start
    }

    mutating func skipSpaces() {
        while index < bytes.count, bytes[index] == UInt8(ascii: " ") {
            index += 1
        }
    }

    mutating func take(_ character: Unicode.Scalar) -> Bool {
        guard index < bytes.count, bytes[index] == UInt8(ascii: character) else { return false }
        index += 1
        return true
    }

    mutating func sign() -> Int? {
        if take("+") { return 1 }
        if take("-") { return -1 }
        return nil
    }
}

// MARK: - Columns

/// A column the plugins' table listings share, by the alias their SQL gives it. The order of the
/// cases is the order the list shows them in.
internal enum ObjectListingField: CaseIterable, Sendable {
    case name
    case rows
    case dataSize
    case engine
    case created
    case updated
    case collation
    case comment
    case schema
    case kind
    case charset
    case totalSize
    case indexSize

    /// `rows`, `data_length` and `index_length` are how MySQL's `SHOW TABLE STATUS` fallback names them.
    init?(alias: String) {
        switch alias.lowercased() {
        case "name": self = .name
        case "estimated_rows", "rows": self = .rows
        case "data_size", "data_length": self = .dataSize
        case "engine": self = .engine
        case "create_time": self = .created
        case "update_time": self = .updated
        case "collation": self = .collation
        case "comment": self = .comment
        case "schema", "schema_name": self = .schema
        case "kind": self = .kind
        case "charset": self = .charset
        case "total_size": self = .totalSize
        case "index_size", "index_length": self = .indexSize
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .rows: String(localized: "Rows")
        case .dataSize: String(localized: "Data Length")
        case .engine: String(localized: "Engine")
        case .created: String(localized: "Created Date")
        case .updated: String(localized: "Modified Date")
        case .collation: String(localized: "Collation")
        case .comment: String(localized: "Comment")
        case .schema: String(localized: "Schema")
        case .kind: String(localized: "Type")
        case .charset: String(localized: "Charset")
        case .totalSize: String(localized: "Total Size")
        case .indexSize: String(localized: "Index Size")
        }
    }

    var format: ObjectListingValueFormat {
        switch self {
        case .rows: .count
        case .dataSize, .totalSize, .indexSize: .bytes
        case .created, .updated: .date
        case .name, .engine, .collation, .comment, .schema, .kind, .charset: .text
        }
    }

    /// The type repeats the kind the picker names, the charset repeats the collation, and the total and
    /// index sizes add little beside the data length. A user can still show any of them.
    var isShownByDefault: Bool {
        switch self {
        case .schema, .kind, .charset, .totalSize, .indexSize: false
        case .name, .rows, .dataSize, .engine, .created, .updated, .collation, .comment: true
        }
    }
}

/// One column of the Objects list.
internal struct ObjectListingColumn: Equatable, Identifiable, Sendable {
    /// The plugin's alias or the built column's key, lowercased. A saved show or hide choice keys on it.
    let id: String
    let title: String
    /// Where the column's values sit in each listing row.
    let valueIndex: Int
    let format: ObjectListingValueFormat
    let isShownByDefault: Bool
}

internal enum ObjectListingColumnLayout {
    /// The listing's columns in the list's order: the known ones in `ObjectListingField` order, the
    /// visible ones first, and a column only this plugin lists after Comment in the plugin's order.
    ///
    /// `containerName` is the database or schema the tab lists. A Schema column naming only it says
    /// nothing, and neither does a column every row left empty, so both start hidden.
    static func columns(of listing: TableListing, containerName: String?) -> [ObjectListingColumn] {
        let titles = listing.rows.columns
        let keys = titles.indices.map { index in
            listing.columnKeys.indices.contains(index) ? listing.columnKeys[index] : titles[index].lowercased()
        }
        let fields = keys.map(ObjectListingField.init(alias:))
        let hasDataSize = fields.contains(.dataSize)
        let visibleFieldCount = ObjectListingField.allCases.filter(\.isShownByDefault).count

        func rank(_ index: Int) -> Double {
            // A total stands in for the data length a listing lacks, so it takes that place.
            let field = fields[index] == .totalSize && !hasDataSize ? .dataSize : fields[index]
            guard let field, let order = ObjectListingField.allCases.firstIndex(of: field) else {
                return Double(visibleFieldCount) - 0.5
            }
            return Double(order)
        }

        var seen: Set<String> = []
        let ordered = titles.indices.sorted { (rank($0), $0) < (rank($1), $1) }
        return ordered.map { index in
            let field = fields[index]
            var id = keys[index]
            if !seen.insert(id).inserted {
                id = "\(id)#\(index)"
                seen.insert(id)
            }
            return ObjectListingColumn(
                id: id,
                title: field?.title ?? titles[index],
                valueIndex: index,
                format: field?.format ?? .text,
                isShownByDefault: isShownByDefault(
                    field,
                    valueIndex: index,
                    rows: listing.rows,
                    hasDataSize: hasDataSize,
                    containerName: containerName
                )
            )
        }
    }

    private static func isShownByDefault(
        _ field: ObjectListingField?,
        valueIndex: Int,
        rows: TableRows,
        hasDataSize: Bool,
        containerName: String?
    ) -> Bool {
        let values = rows.rows.compactMap { $0[valueIndex].asText?.nilIfEmpty }
        switch field {
        case .name:
            return true
        case .schema:
            return values.contains { $0 != containerName }
        case .totalSize where !hasDataSize:
            return !values.isEmpty
        default:
            return (field?.isShownByDefault ?? true) && !values.isEmpty
        }
    }
}

// MARK: - Rows

/// One object as the Objects list draws it.
internal struct ObjectListingRow: Equatable, Identifiable, Sendable {
    let id: RowID
    let item: ObjectListingItem
    /// The drawn text of each value, by value index.
    let texts: [String]
    let sortKeys: [ObjectListingSortKey]
}

/// The column the reader sorted the list by.
internal struct ObjectListingSort: Equatable, Sendable {
    let columnID: String
    let ascending: Bool
}

internal enum ObjectListingRowBuilder {
    /// A row with no name, which names no object, is left out: nothing could open it.
    static func rows(
        of listing: TableListing,
        columns: [ObjectListingColumn],
        formatter: ObjectListingValueFormatter
    ) -> [ObjectListingRow] {
        let formats = Dictionary(columns.map { ($0.valueIndex, $0.format) }, uniquingKeysWith: { first, _ in first })
        let valueCount = listing.rows.columns.count
        return listing.rows.rows.compactMap { row in
            guard let item = listing.items[row.id] else { return nil }
            var texts: [String] = []
            var keys: [ObjectListingSortKey] = []
            texts.reserveCapacity(valueCount)
            keys.reserveCapacity(valueCount)
            for index in 0 ..< valueCount {
                let format = formats[index] ?? .text
                texts.append(formatter.display(row[index], as: format))
                keys.append(formatter.sortKey(row[index], as: format))
            }
            return ObjectListingRow(id: row.id, item: item, texts: texts, sortKeys: keys)
        }
    }

    /// Ties keep the listing's own order, so a second click on a column never shuffles equal rows.
    static func sorted(
        _ rows: [ObjectListingRow],
        by sort: ObjectListingSort?,
        columns: [ObjectListingColumn]
    ) -> [ObjectListingRow] {
        guard let sort, let column = columns.first(where: { $0.id == sort.columnID }) else { return rows }
        let index = column.valueIndex
        return rows.enumerated().sorted { lhs, rhs in
            let left = lhs.element.sortKeys.indices.contains(index) ? lhs.element.sortKeys[index] : .missing
            let right = rhs.element.sortKeys.indices.contains(index) ? rhs.element.sortKeys[index] : .missing
            if left < right { return sort.ascending }
            if right < left { return !sort.ascending }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }
}

extension ObjectListingItem {
    /// The kind the sidebar draws the same object as. A type is drawn as the Types section is, not
    /// by its own shape.
    var iconKind: ObjectIconKind {
        switch self {
        case .relation(_, _, let type): return .relation(type)
        case .sourced(let ref): return ref.kind.sidebarObjectKind.map(ObjectIconKind.init) ?? ObjectIconKind(ref)
        }
    }
}
