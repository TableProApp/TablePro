import Foundation

public enum TrinoLiteral {
    private static let numericBaseTypes: Set<String> = [
        "tinyint", "smallint", "integer", "int", "bigint", "real", "double", "decimal"
    ]

    public static func render(_ value: TrinoValue, typeName: String) -> String {
        switch value {
        case .null:
            return "NULL"
        case .bytes(let bytes):
            return "X'" + bytes.map { String(format: "%02X", $0) }.joined() + "'"
        case .text(let text):
            return renderText(text, typeName: typeName)
        }
    }

    static func renderText(_ text: String, typeName: String) -> String {
        let base = TrinoTypeMapper.baseType(fromDisplayType: typeName)

        if base == "boolean" {
            let lower = text.lowercased()
            if lower == "true" || lower == "false" { return lower }
            return quoted(text)
        }
        if numericBaseTypes.contains(base) {
            return isNumeric(text) ? text : quoted(text)
        }
        if base.hasPrefix("timestamp") {
            return "TIMESTAMP " + quoted(text)
        }
        if base.hasPrefix("time") {
            return "TIME " + quoted(text)
        }
        if base.hasPrefix("date") {
            return "DATE " + quoted(text)
        }
        if base == "json" {
            return "JSON " + quoted(text)
        }
        if base == "uuid" {
            return "UUID " + quoted(text)
        }
        if base == "ipaddress" {
            return "CAST(" + quoted(text) + " AS ipaddress)"
        }
        if base == "varbinary" {
            return "from_hex(" + quoted(text) + ")"
        }
        if base == "array" || base == "map" || base == "row" {
            return "CAST(json_parse(" + quoted(text) + ") AS " + typeName + ")"
        }
        return quoted(text)
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func isNumeric(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var seenDigit = false
        var seenDot = false
        var seenExponent = false
        var iterator = text.makeIterator()
        var isFirst = true
        while let character = iterator.next() {
            if isFirst {
                isFirst = false
                if character == "-" || character == "+" { continue }
            }
            if character.isNumber {
                seenDigit = true
                continue
            }
            if character == ".", !seenDot, !seenExponent {
                seenDot = true
                continue
            }
            if (character == "e" || character == "E"), seenDigit, !seenExponent {
                seenExponent = true
                seenDigit = false
                if let next = iterator.next() {
                    if next == "+" || next == "-" { continue }
                    if next.isNumber { seenDigit = true; continue }
                }
                return false
            }
            return false
        }
        return seenDigit
    }
}
