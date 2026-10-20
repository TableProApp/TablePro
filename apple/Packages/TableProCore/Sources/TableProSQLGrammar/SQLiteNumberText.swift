import Foundation

// SQLite keeps integer 5 and text '5' apart in a column with no affinity, and reads both back as `5`.
// A value is matched both ways only when it has the shape SQLite prints a number in, so `05` or `5.50`
// never also finds the row that reads `5` or `5.5`.
public enum SQLiteNumberText {
    public static func isStoredSpelling(_ text: String) -> Bool {
        if let integer = Int64(text) { return String(integer) == text }
        guard let real = Double(text), real.isFinite, text.utf8.allSatisfy({ $0 < 0x80 }) else { return false }
        return isRealSpelling(text, real: real)
    }

    // An integer compares exactly against a column of any affinity; a REAL against a TEXT column does not.
    public static func isIntegerSpelling(_ text: String) -> Bool {
        Int64(text).map { String($0) == text } ?? false
    }

    // Measured on SQLite 3.54: a REAL prints with 15 significant digits when they read back as the same value and
    // with 17 when they do not, never a trailing zero but the one in `7.0`, plain from 1e-4 below 1e17
    // (`0.0001`, `10000000000000000.0`), else as `1.0e-05` or `1.2e+17`. The 17 digits are SQLite's own
    // (1/3 prints `0.33333333333333332`), so their shape is checked, not their last digit.
    private static func isRealSpelling(_ text: String, real: Double) -> Bool {
        let isZero = real == 0
        let unsigned = text.hasPrefix("-") ? String(text.dropFirst()) : text
        if isZero { return text == "0.0" }
        let parts = unsigned.split(separator: "e", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard mantissa.count == 2, let whole = mantissa.first, let fraction = mantissa.last,
              !whole.isEmpty, !fraction.isEmpty,
              whole.allSatisfy(\.isASCIIDigit), fraction.allSatisfy(\.isASCIIDigit),
              whole == "0" || whole.first != "0",
              fraction == "0" || fraction.last != "0"
        else { return false }

        let digits = (whole + fraction).drop { $0 == "0" }
        let significant = fraction == "0" ? digits.reversed().drop { $0 == "0" }.count : digits.count
        guard significant <= 15 || significant <= 17 && needsMoreThanFifteenDigits(real) else { return false }

        guard parts.count == 2 else {
            let exponent = whole == "0"
                ? -(fraction.prefix { $0 == "0" }.count + 1)
                : whole.count - 1
            return (-4...16).contains(exponent)
        }
        let written = parts[1]
        guard whole.count == 1, whole != "0", let sign = written.first, sign == "+" || sign == "-" else { return false }
        let exponentDigits = written.dropFirst()
        guard exponentDigits.count >= 2, exponentDigits.allSatisfy(\.isASCIIDigit),
              exponentDigits.count == 2 || exponentDigits.first != "0",
              let magnitude = Int(exponentDigits)
        else { return false }
        return !(-4...16).contains(sign == "-" ? -magnitude : magnitude)
    }
}

private func needsMoreThanFifteenDigits(_ real: Double) -> Bool {
    let shortest = "\(abs(real))".prefix { $0 != "e" }.filter(\.isNumber).drop { $0 == "0" }
    return shortest.reversed().drop { $0 == "0" }.count > 15
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
