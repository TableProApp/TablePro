import Foundation
import TableProSQLQuoting

public enum TrinoLiteral {
    private static let numericBaseTypes: Set<String> = [
        "tinyint", "smallint", "integer", "int", "bigint", "real", "double", "decimal"
    ]

    // Nil when a structured value would be cast to a type that does not read as one.
    public static func render(_ value: TrinoValue, typeName: String) -> String? {
        switch value {
        case .null:
            return "NULL"
        case .bytes(let bytes):
            return "X'" + bytes.map { String(format: "%02X", $0) }.joined() + "'"
        case .text(let text):
            return renderText(text, typeName: typeName)
        }
    }

    static func renderText(_ text: String, typeName: String) -> String? {
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
            guard TrinoTypeMapper.isWritable(typeName) else { return nil }
            return "CAST(json_parse(" + quoted(text) + ") AS " + typeName + ")"
        }
        return quoted(text)
    }

    static func quoted(_ text: String) -> String {
        SQLQuoting.stringLiteral(text)
    }

    // ASCII digits by scalar: Trino reads `١٢`, `１` or a digit a combining mark follows as no number.
    static func isNumeric(_ text: String) -> Bool {
        var seenDigit = false
        var seenDot = false
        var seenExponent = false
        var iterator = text.unicodeScalars.makeIterator()
        var isFirst = true
        while let scalar = iterator.next() {
            defer { isFirst = false }
            if isFirst, scalar == "-" || scalar == "+" { continue }
            if isDigit(scalar) {
                seenDigit = true
                continue
            }
            if scalar == ".", !seenDot, !seenExponent {
                seenDot = true
                continue
            }
            if scalar == "e" || scalar == "E", seenDigit, !seenExponent {
                seenExponent = true
                seenDigit = false
                guard let next = iterator.next() else { return false }
                if isDigit(next) {
                    seenDigit = true
                } else if next != "+", next != "-" {
                    return false
                }
                continue
            }
            return false
        }
        return seenDigit
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }
}
