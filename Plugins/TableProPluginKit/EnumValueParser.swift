import Foundation

public enum EnumValueParser {
    public static func parseMySQLEnumOrSet(from typeString: String) -> [String]? {
        let upper = typeString.uppercased()
        guard upper.hasPrefix("ENUM(") || upper.hasPrefix("SET(") else {
            return nil
        }
        return parseQuotedList(in: typeString)
    }

    public static func parseClickHouseEnum(from typeString: String) -> [String]? {
        let upper = typeString.uppercased()
        guard upper.hasPrefix("ENUM8(") || upper.hasPrefix("ENUM16(") else {
            return nil
        }
        return parseQuotedList(in: typeString, ignoreAfterQuote: true)
    }

    private static func parseQuotedList(in typeString: String, ignoreAfterQuote: Bool = false) -> [String]? {
        guard let openParen = typeString.firstIndex(of: "("),
              let closeParen = typeString.lastIndex(of: ")") else {
            return nil
        }
        let inner = typeString[typeString.index(after: openParen)..<closeParen]

        var values: [String] = []
        var current = ""
        var inQuote = false
        var escaped = false

        for char in inner {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }
            if char == "\\" {
                escaped = true
                continue
            }
            if char == "'" {
                if inQuote {
                    if ignoreAfterQuote {
                        values.append(current)
                        current = ""
                    }
                    inQuote = false
                } else {
                    inQuote = true
                }
                continue
            }
            if inQuote {
                current.append(char)
                continue
            }
            if !ignoreAfterQuote, char == "," {
                values.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        if !ignoreAfterQuote, !current.isEmpty {
            values.append(current.trimmingCharacters(in: .whitespaces))
        }
        return values.isEmpty ? nil : values
    }
}
