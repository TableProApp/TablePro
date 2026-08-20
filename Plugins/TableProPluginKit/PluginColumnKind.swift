//
//  PluginColumnKind.swift
//  TableProPluginKit
//

import Foundation

public enum PluginColumnKind: String, Sendable {
    case text
    case integer
    case decimal
    case boolean
    case other
}

public enum PluginBooleanSynonym: Sendable {
    case isTrue
    case isFalse
}

public enum PluginSQLLiteral {
    public static func isIntegerLiteral(_ value: String) -> Bool {
        var iter = value.unicodeScalars.makeIterator()
        guard var first = iter.next() else { return false }
        if first == "-" {
            guard let next = iter.next() else { return false }
            first = next
        }
        guard first >= "0" && first <= "9" else { return false }
        while let next = iter.next() {
            guard next >= "0" && next <= "9" else { return false }
        }
        return true
    }

    public static func isNumericLiteral(_ value: String, kind: PluginColumnKind?) -> Bool {
        guard let kind else {
            return Int(value) != nil || Double(value) != nil
        }
        switch kind {
        case .integer:
            return isIntegerLiteral(value)
        case .decimal:
            return PluginNumericLiteral.isValid(value)
        case .text, .boolean, .other:
            return false
        }
    }

    public static func isKnownTextLike(_ kind: PluginColumnKind?) -> Bool {
        kind == .text
    }

    public static func supportsEmptyStringComparison(_ kind: PluginColumnKind?) -> Bool {
        guard let kind else { return true }
        return kind == .text
    }

    public static func booleanSynonym(for value: String) -> PluginBooleanSynonym? {
        switch value.lowercased() {
        case "true", "1", "yes", "on":
            return .isTrue
        case "false", "0", "no", "off":
            return .isFalse
        default:
            return nil
        }
    }

    public static func booleanSynonym(for value: String, kind: PluginColumnKind?) -> PluginBooleanSynonym? {
        guard let kind else { return legacyBooleanSynonym(for: value) }
        guard kind == .boolean else { return nil }
        return booleanSynonym(for: value)
    }

    public static func escapedLiteral(
        _ value: String,
        kind: PluginColumnKind?,
        trueLiteral: String?,
        falseLiteral: String?,
        quote: (String) -> String
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        if !isKnownTextLike(kind), trimmed.caseInsensitiveCompare("NULL") == .orderedSame {
            return "NULL"
        }

        if let trueLiteral, let falseLiteral, let synonym = booleanSynonym(for: trimmed, kind: kind) {
            switch synonym {
            case .isTrue:
                return trueLiteral
            case .isFalse:
                return falseLiteral
            }
        }

        if isNumericLiteral(trimmed, kind: kind) {
            return trimmed
        }

        return quote(trimmed)
    }

    private static func legacyBooleanSynonym(for value: String) -> PluginBooleanSynonym? {
        if value.caseInsensitiveCompare("TRUE") == .orderedSame { return .isTrue }
        if value.caseInsensitiveCompare("FALSE") == .orderedSame { return .isFalse }
        return nil
    }
}
