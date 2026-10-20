import Foundation

// SQLite keeps integer 5 and text '5' apart in a column with no affinity, and reads both back as `5`.
// A value is matched both ways only when it has the shape SQLite prints a number in, so `05` or `5.50`
// never also finds the row that reads `5` or `5.5`.
public enum SQLiteNumberText {
    public static func isStoredSpelling(_ text: String) -> Bool {
        if let integer = Int64(text) { return String(integer) == text }
        guard let real = Double(text), real.isFinite, text.utf8.allSatisfy({ $0 < 0x80 }) else { return false }
        return isRealSpelling(text, isZero: real == 0)
    }

    // An integer compares exactly against a column of any affinity; a REAL against a TEXT column does not.
    public static func isIntegerSpelling(_ text: String) -> Bool {
        Int64(text).map { String($0) == text } ?? false
    }

    // A REAL prints with at most 17 significant digits, never a trailing zero but the one in `7.0`, either plain or as
    // `1.0e-05` and `1.2e+17`. SQLite 3.54 goes plain from 1e-4 below 1e17 and an older one past 1e15, and the digits
    // are SQLite's own (1/3 prints `0.33333333333333332`), so only the shape is checked; the caller's CAST holds the
    // match to the exact text.
    private static func isRealSpelling(_ text: String, isZero: Bool) -> Bool {
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
        guard significant <= 17 else { return false }

        guard parts.count == 2 else { return true }
        let written = parts[1]
        guard whole.count == 1, whole != "0", let sign = written.first, sign == "+" || sign == "-" else { return false }
        let exponentDigits = written.dropFirst()
        return exponentDigits.count >= 2 && exponentDigits.allSatisfy(\.isASCIIDigit)
            && (exponentDigits.count == 2 || exponentDigits.first != "0")
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
