import Foundation

public enum EnumValueParser {
    public static func parseMySQLEnumOrSet(from typeString: String) -> [String]? {
        let upper = typeString.uppercased()
        guard upper.hasPrefix("ENUM(") || upper.hasPrefix("SET(") else {
            return nil
        }
        return parseQuotedList(in: typeString, mode: .csv)
    }

    public static func parseClickHouseEnum(from typeString: String) -> [String]? {
        let upper = typeString.uppercased()
        guard upper.hasPrefix("ENUM8(") || upper.hasPrefix("ENUM16(") else {
            return nil
        }
        return parseQuotedList(in: typeString, mode: .quotedOnly)
    }

    private enum ParseMode {
        case csv
        case quotedOnly
    }

    private static func parseQuotedList(in typeString: String, mode: ParseMode) -> [String]? {
        guard let openParen = typeString.firstIndex(of: "("),
              let closeParen = typeString.lastIndex(of: ")") else {
            return nil
        }
        let inner = typeString[typeString.index(after: openParen)..<closeParen]
        let scalars = Array(inner)

        var values: [String] = []
        var current = ""
        var inQuote = false
        var index = 0

        while index < scalars.count {
            let char = scalars[index]
            if inQuote {
                if char == "\\", index + 1 < scalars.count {
                    current.append(scalars[index + 1])
                    index += 2
                    continue
                }
                if char == "'" {
                    if index + 1 < scalars.count, scalars[index + 1] == "'" {
                        current.append("'")
                        index += 2
                        continue
                    }
                    if mode == .quotedOnly {
                        values.append(current)
                        current = ""
                    }
                    inQuote = false
                    index += 1
                    continue
                }
                current.append(char)
                index += 1
                continue
            }
            if char == "'" {
                inQuote = true
                index += 1
                continue
            }
            if mode == .csv, char == "," {
                values.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
            index += 1
        }
        if mode == .csv, !current.isEmpty {
            values.append(current.trimmingCharacters(in: .whitespaces))
        }
        return values.isEmpty ? nil : values
    }
}
