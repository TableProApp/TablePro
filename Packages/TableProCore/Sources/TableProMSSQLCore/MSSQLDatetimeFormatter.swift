import Foundation

public enum MSSQLDatetimeFormatter {
    public static func reformat(_ raw: String, type: MSSQLColumnType) -> String? {
        guard type.isDateOrTime else { return nil }
        return parse(raw)
    }

    public static func parse(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isAlreadyISO(trimmed) {
            return trimmed
        }
        return parseLegacyAMPM(trimmed)
    }

    public static func isAlreadyISO(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count >= 10 else { return false }
        return chars[0].isASCIIDigit && chars[1].isASCIIDigit
            && chars[2].isASCIIDigit && chars[3].isASCIIDigit
            && chars[4] == "-"
            && chars[5].isASCIIDigit && chars[6].isASCIIDigit
            && chars[7] == "-"
            && chars[8].isASCIIDigit && chars[9].isASCIIDigit
    }

    private static func parseLegacyAMPM(_ raw: String) -> String? {
        let scanner = Scanner(string: raw)
        scanner.charactersToBeSkipped = nil
        _ = scanner.scanCharacters(from: .whitespaces)

        guard let monthToken = scanner.scanCharacters(from: .letters),
              monthToken.count >= 3,
              let month = monthNamesByPrefix[String(monthToken.prefix(3))]
        else { return nil }

        _ = scanner.scanCharacters(from: .whitespaces)
        guard let day = scanner.scanInt(), (1...31).contains(day) else { return nil }
        _ = scanner.scanCharacters(from: .whitespaces)
        guard let year = scanner.scanInt(), (1...9999).contains(year) else { return nil }
        _ = scanner.scanCharacters(from: .whitespaces)
        guard var hour = scanner.scanInt() else { return nil }

        var minute = 0
        var second = 0
        var fractional = ""

        if scanner.scanString(":") != nil {
            guard let m = scanner.scanInt(), (0...59).contains(m) else { return nil }
            minute = m
        }
        if scanner.scanString(":") != nil {
            guard let s = scanner.scanInt(), (0...59).contains(s) else { return nil }
            second = s
        }
        if scanner.scanString(":") != nil || scanner.scanString(".") != nil {
            fractional = scanner.scanCharacters(from: .decimalDigits) ?? ""
        }

        _ = scanner.scanCharacters(from: .whitespaces)
        let ampm = scanner.scanCharacters(from: .letters)?.uppercased()

        if let ampm {
            guard ampm == "AM" || ampm == "PM" else { return nil }
            guard (1...12).contains(hour) else { return nil }
            if ampm == "PM", hour < 12 {
                hour += 12
            } else if ampm == "AM", hour == 12 {
                hour = 0
            }
        } else {
            guard (0...23).contains(hour) else { return nil }
        }

        var iso = String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
        if !fractional.isEmpty {
            iso += "." + fractional
        }
        return iso
    }

    private static let monthNamesByPrefix: [String: Int] = [
        "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
        "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12
    ]
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
