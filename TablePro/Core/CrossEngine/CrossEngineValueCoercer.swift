//
//  CrossEngineValueCoercer.swift
//  TablePro
//
//  Reshapes the values a row carries so the other engine accepts them.
//
//  Values cross as `PluginCellValue`, which is text, bytes or null, and each
//  one is bound as a parameter rather than written into SQL. That is already
//  enough for almost everything: a number, a string and a blob all mean the
//  same thing to both sides. Three things do not, and each of them fails in a
//  way that is hard to read from the far end of a long copy.
//
//  PostgreSQL renders a boolean as `t` and `f`. Bound into a MySQL
//  `TINYINT(1)` that is 0 in both cases outside strict mode, so every `true` in
//  the table silently becomes `false`, and inside strict mode it is an error on
//  the first row. MySQL renders a missing date as `0000-00-00`, which no other
//  engine will accept at all. And a `TIMESTAMPTZ` arrives carrying `+07`, which
//  a target column with no time zone rejects.
//
//  Nothing here guesses at a value's meaning: each coercion is chosen from the
//  target column's own canonical kind, so a `t` in a text column stays `t`.
//

import Foundation
import TableProPluginKit

internal struct CrossEngineValueCoercer: Sendable {
    /// One written column, said on both sides of the crossing.
    ///
    /// Neither side answers on its own. `t` is a boolean because the *source* column was one, and
    /// nothing about a MySQL `TINYINT(1)` says the value arriving is not the literal letter t. A
    /// time zone is dropped because the *target* has none, and nothing about a PostgreSQL
    /// `timestamptz` says where it is going.
    internal struct ColumnPair: Sendable {
        internal let source: CanonicalTypeKind?
        internal let target: CanonicalTypeKind?
    }

    private let pairs: [ColumnPair]
    private let sourceFamily: SQLTypeFamily
    private let positions: [Int]

    internal init(pairs: [ColumnPair], from sourceFamily: SQLTypeFamily) {
        self.pairs = pairs
        self.sourceFamily = sourceFamily
        self.positions = pairs.enumerated()
            .filter { Self.needsCoercion($0.element) }
            .map(\.offset)
    }

    /// Whether any column in this table needs looking at, so a table of numbers and strings runs
    /// the same loop it ran before this existed.
    internal var isNeeded: Bool { !positions.isEmpty }

    internal func coerce(_ row: [PluginCellValue]) -> [PluginCellValue] {
        guard isNeeded else { return row }
        var values = row
        for index in positions where index < values.count {
            values[index] = coerce(values[index], pair: pairs[index])
        }
        return values
    }

    // MARK: - One value

    private func coerce(_ value: PluginCellValue, pair: ColumnPair) -> PluginCellValue {
        if Self.carriesBoolean(pair) { return boolean(value) }
        switch pair.target {
        case .date, .time, .timestamp:
            return temporal(value, kind: pair.target)
        case .json:
            return json(value)
        default:
            return value
        }
    }

    /// A boolean the target will store as a number or a boolean.
    ///
    /// Not one going into text: a `boolean` column copied into a `VARCHAR` keeps whatever the
    /// source wrote, because `t` is the value there rather than a spelling of one, and rewriting it
    /// to `1` would change the data rather than carry it.
    private static func carriesBoolean(_ pair: ColumnPair) -> Bool {
        guard case .boolean = pair.source else { return false }
        switch pair.target {
        case .boolean, .integer, .decimal, .bitString, nil: return true
        default: return false
        }
    }

    /// Every engine here reads `1` and `0` in a boolean column, and none of them reads all of
    /// `t`, `true`, `yes` and `on`. A value that is none of those is left alone rather than
    /// guessed at, so a column the source did not really use as a boolean fails visibly.
    private func boolean(_ value: PluginCellValue) -> PluginCellValue {
        switch value {
        case .null:
            return value
        case .bytes(let data):
            guard data.count == 1, let byte = data.first else { return value }
            return .text(byte == 0 ? "0" : "1")
        case .text(let text):
            switch PluginSQLLiteral.booleanSynonym(for: text) {
            case .isTrue: return .text("1")
            case .isFalse: return .text("0")
            case nil: return Self.singleLetterBoolean(text) ?? value
            /// `PluginBooleanSynonym` is published by a resilient library, so it can gain a case a
            /// build compiled against today's PluginKit has never seen. One it cannot name is one
            /// it cannot spell for the target either, so the value is left as it came.
            @unknown default: return value
            }
        }
    }

    /// PostgreSQL's own rendering of a boolean, which `PluginSQLLiteral` does not cover because
    /// `t` and `f` are ordinary text everywhere else.
    private static func singleLetterBoolean(_ text: String) -> PluginCellValue? {
        switch text.lowercased() {
        case "t": return .text("1")
        case "f": return .text("0")
        default: return nil
        }
    }

    private func temporal(_ value: PluginCellValue, kind: CanonicalTypeKind?) -> PluginCellValue {
        guard case .text(let text) = value else { return value }
        if sourceFamily == .mysql, Self.isZeroDate(text) { return .null }
        guard !hasTimeZone(kind) else { return value }
        guard let stripped = Self.strippingTimeZoneOffset(text) else { return value }
        return .text(stripped)
    }

    /// A PostgreSQL array arrives as `{1,2,3}`, which a JSON column on the target rejects. The
    /// elements are the same; only the brackets and the quoting differ.
    private func json(_ value: PluginCellValue) -> PluginCellValue {
        guard sourceFamily == .postgres, case .text(let text) = value else { return value }
        guard text.hasPrefix("{"), text.hasSuffix("}") else { return value }
        guard let elements = PostgresArrayLiteralCodec.parse(text) else { return value }
        var items: [String] = []
        items.reserveCapacity(elements.count)
        for element in elements {
            switch element {
            case .null:
                items.append("null")
            case .value(let raw):
                items.append(Self.jsonScalar(raw))
            /// A case this build has never seen cannot be rendered as JSON, and a wrong guess would
            /// be written into every row. The value is left as the array literal it arrived as.
            @unknown default:
                return value
            }
        }
        return .text("[\(items.joined(separator: ","))]")
    }

    private func hasTimeZone(_ kind: CanonicalTypeKind?) -> Bool {
        switch kind {
        case .time(_, let hasTimeZone), .timestamp(_, let hasTimeZone): return hasTimeZone
        default: return false
        }
    }

    // MARK: - Shapes

    private static func needsCoercion(_ pair: ColumnPair) -> Bool {
        if carriesBoolean(pair) { return true }
        switch pair.target {
        case .date, .time, .timestamp, .json: return true
        default: return false
        }
    }

    internal static func isZeroDate(_ text: String) -> Bool {
        text.hasPrefix("0000-00-00")
    }

    /// The trailing `+07`, `+07:00`, `-0330` or `Z` a zone-aware value carries. Removed only when
    /// what is left still looks like a date, so a plain `2024-01-01` and a negative number are both
    /// left alone.
    internal static func strippingTimeZoneOffset(_ text: String) -> String? {
        guard let expression = zonedTimestamp else { return nil }
        let subject = text as NSString
        let whole = NSRange(location: 0, length: subject.length)
        guard let match = expression.firstMatch(in: text, options: [], range: whole),
              match.range == whole, match.numberOfRanges > 1 else {
            return nil
        }
        return subject.substring(with: match.range(at: 1))
    }

    private static let zonedTimestamp: NSRegularExpression? = {
        let pattern = "^(\\d{4}-\\d{2}-\\d{2}[ T]\\d{2}:\\d{2}(?::\\d{2}(?:\\.\\d+)?)?)"
            + "\\s*(?:Z|[+-]\\d{2}(?::?\\d{2})?)$"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func jsonScalar(_ raw: String) -> String {
        if raw == "true" || raw == "false" { return raw }
        if Int64(raw) != nil || Double(raw) != nil { return raw }
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
