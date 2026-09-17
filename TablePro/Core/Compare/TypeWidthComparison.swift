//
//  TypeWidthComparison.swift
//  TablePro
//
//  Whether a column's new type still holds every value the old one did.
//
//  Each parameter is read for what it means on the engine writing it, because the same number in
//  the same position means different things: the 3 in `numeric(12,3)` is a count of decimal places
//  and the 3 in `datetime(3)` is a count of fractional-second digits, whose absence is six digits on
//  PostgreSQL and none at all on MySQL. Compared as one leading integer, `numeric(10,2)` to
//  `numeric(12,6)` reads as widening while it drops two integer digits, and `DATETIME` to
//  `DATETIME(3)` reads as unchanged while it gains milliseconds.
//

import Foundation

internal enum TypeWidthComparison {
    internal enum Outcome {
        case widening
        case narrowing
        case equivalent
    }

    internal static func classify(from oldType: String, to newType: String, family: SQLTypeFamily) -> Outcome {
        let old = Spelling(oldType)
        let new = Spelling(newType)
        guard old.base == new.base else { return .narrowing }
        if old.base == setTypeName {
            return labelOutcome(from: SQLTypeParser.labels(in: old.params), to: SQLTypeParser.labels(in: new.params))
        }
        let outcome = kindOutcome(
            from: SQLTypeParser.parse(oldType, family: family).kind,
            to: SQLTypeParser.parse(newType, family: family).kind,
            family: family
        )
        return outcome ?? leadingIntegerOutcome(from: old, to: new)
    }

    private static func kindOutcome(
        from old: CanonicalTypeKind,
        to new: CanonicalTypeKind,
        family: SQLTypeFamily
    ) -> Outcome? {
        switch (old, new) {
        case let (.text(oldLength, _), .text(newLength, _)),
             let (.binary(oldLength, _), .binary(newLength, _)),
             let (.bitString(oldLength), .bitString(newLength)):
            return boundOutcome(from: oldLength, to: newLength)
        case let (.decimal(oldPrecision, oldScale), .decimal(newPrecision, newScale)):
            return decimalOutcome(from: (oldPrecision, oldScale), to: (newPrecision, newScale))
        case let (.time(oldPrecision, _), .time(newPrecision, _)),
             let (.timestamp(oldPrecision, _), .timestamp(newPrecision, _)):
            return fractionalSecondsOutcome(from: oldPrecision, to: newPrecision, family: family)
        case let (.enumeration(oldValues), .enumeration(newValues)):
            return labelOutcome(from: oldValues, to: newValues)
        /// A MySQL integer's parameter is its display width, which decides how `ZEROFILL` pads and
        /// nothing else. MySQL 8.0.19 stopped reporting it, so a MariaDB `int(11)` and a MySQL `int`
        /// are the same column.
        case (.integer, .integer):
            return .equivalent
        case let (.array(oldElement), .array(newElement)):
            return kindOutcome(from: oldElement, to: newElement, family: family)
        default:
            return nil
        }
    }

    /// A length or precision the old type did not declare is every value the type can hold, so
    /// declaring one narrows it: `varchar` to `varchar(50)` refuses the fifty-first character.
    private static func boundOutcome(from old: Int?, to new: Int?) -> Outcome {
        switch (old, new) {
        case (nil, nil): return .equivalent
        case (nil, .some): return .narrowing
        case (.some, nil): return .widening
        case let (.some(oldLength), .some(newLength)): return compare(from: oldLength, to: newLength)
        }
    }

    /// Both halves of a decimal are read, because the digits before the point and the digits after
    /// it are separate limits: `numeric(12,4)` to `numeric(12,2)` keeps the precision and rounds
    /// 1.2345 to 1.23, and `numeric(10,2)` to `numeric(12,6)` gains a decimal place while losing two
    /// integer digits. A scale a type does not declare is zero, which is what every engine stores.
    private static func decimalOutcome(from old: (Int?, Int?), to new: (Int?, Int?)) -> Outcome {
        guard let oldPrecision = old.0 else { return new.0 == nil ? .equivalent : .narrowing }
        guard let newPrecision = new.0 else { return .widening }
        let oldScale = old.1 ?? 0
        let newScale = new.1 ?? 0
        let oldIntegerDigits = oldPrecision - oldScale
        let newIntegerDigits = newPrecision - newScale
        if newScale < oldScale || newIntegerDigits < oldIntegerDigits { return .narrowing }
        if newScale > oldScale || newIntegerDigits > oldIntegerDigits { return .widening }
        return .equivalent
    }

    /// A type that declares no fractional-second digits takes the engine's own default, and the two
    /// engines that meet in a sync disagree about it: PostgreSQL keeps microseconds where MySQL
    /// keeps whole seconds. An engine whose default is not known here compares as unchanged rather
    /// than guessing one.
    private static func fractionalSecondsOutcome(from old: Int?, to new: Int?, family: SQLTypeFamily) -> Outcome {
        guard let oldDigits = old ?? defaultFractionalSeconds(family),
              let newDigits = new ?? defaultFractionalSeconds(family) else { return .equivalent }
        return compare(from: oldDigits, to: newDigits)
    }

    private static func defaultFractionalSeconds(_ family: SQLTypeFamily) -> Int? {
        switch family {
        case .mysql: return 0
        case .postgres, .oracle, .duckdb: return 6
        case .mssql: return 7
        case .sqlite, .clickhouse, .generic: return nil
        }
    }

    /// Adding a label leaves every stored value spellable; removing one leaves its rows holding a
    /// value the column no longer has. Reordering is neither.
    private static func labelOutcome(from old: [String], to new: [String]) -> Outcome {
        let kept = Set(new)
        if old.contains(where: { !kept.contains($0) }) { return .narrowing }
        return new.count > old.count ? .widening : .equivalent
    }

    /// The reading every other parameter keeps: a leading integer on both sides is a width, and
    /// anything else is a difference this cannot judge.
    private static func leadingIntegerOutcome(from old: Spelling, to new: Spelling) -> Outcome {
        guard let oldWidth = old.leadingInteger, let newWidth = new.leadingInteger else { return .equivalent }
        return compare(from: oldWidth, to: newWidth)
    }

    private static func compare(from old: Int, to new: Int) -> Outcome {
        if new > old { return .widening }
        if new < old { return .narrowing }
        return .equivalent
    }

    private static let setTypeName = "set"

    /// MySQL's `ZEROFILL` pads a number on the way out and says nothing about what it holds, so it
    /// is not part of the type's name. `UNSIGNED` is: it moves the range.
    private static let displayOnlyWords: Set<String> = ["zerofill"]

    /// A type split into the words around its parameters and the parameters themselves. The words
    /// after the parentheses are part of the name: `timestamp(3) with time zone` and
    /// `character varying(20)[]` are not a `timestamp` and a `character varying`.
    private struct Spelling {
        let base: String
        let params: String?

        init(_ type: String) {
            let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let open = trimmed.firstIndex(of: "("),
                  let close = trimmed.lastIndex(of: ")"),
                  open < close else {
                base = Self.collapsingWhitespace(trimmed)
                params = nil
                return
            }
            base = Self.collapsingWhitespace(trimmed[..<open] + trimmed[trimmed.index(after: close)...])
            params = String(trimmed[trimmed.index(after: open)..<close])
        }

        /// The first parameter, and only when it is a whole number on its own: `geometry(Point,4326)`
        /// has no width, and reading the first number anywhere in the list would call its SRID one.
        var leadingInteger: Int? {
            params?.split(separator: ",").first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }

        private static func collapsingWhitespace(_ value: some StringProtocol) -> String {
            value.split(whereSeparator: \.isWhitespace)
                .filter { !TypeWidthComparison.displayOnlyWords.contains(String($0)) }
                .joined(separator: " ")
        }
    }
}
