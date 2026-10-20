import Foundation

// SQLite keeps integer 5 and text '5' apart in a column with no affinity, and reads both back as `5`.
// A value is matched both ways only when it is SQLite's own text for a number, so `05` or `5.50`
// never also finds the row that reads `5` or `5.5`.
public enum SQLiteNumberText {
    public static func isStoredSpelling(_ text: String) -> Bool {
        if let integer = Int64(text) { return String(integer) == text }
        guard let real = Double(text), real.isFinite else { return false }
        return realText(real) == text
    }

    // Measured on SQLite 3.53: the shortest digits that read back, plain from 1e-4 below 1e17 with `.0`
    // when there is no fraction, `1.0e+20` and `1.5e-07` outside that range.
    static func realText(_ real: Double) -> String {
        let sign = real < 0 ? "-" : ""
        let swiftText = "\(abs(real))"
        let parts = swiftText.split(separator: "e", maxSplits: 1)
        let mantissa = String(parts[0])
        let writtenExponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let pointOffset = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) }
            ?? mantissa.count
        let allDigits = mantissa.filter { $0 != "." }
        let leadingZeros = allDigits.prefix { $0 == "0" }.count
        var digits = String(allDigits.dropFirst(leadingZeros))
        while digits.hasSuffix("0") { digits.removeLast() }
        guard !digits.isEmpty else { return "\(sign)0.0" }
        let exponent = pointOffset + writtenExponent - leadingZeros - 1

        guard (-4...16).contains(exponent) else {
            let fraction = digits.dropFirst()
            let exponentSign = exponent < 0 ? "-" : "+"
            let exponentDigits = String(abs(exponent))
            let paddedExponent = exponentDigits.count < 2 ? "0" + exponentDigits : exponentDigits
            return "\(sign)\(digits.prefix(1)).\(fraction.isEmpty ? "0" : fraction)e\(exponentSign)\(paddedExponent)"
        }
        if exponent < 0 {
            return "\(sign)0.\(String(repeating: "0", count: -exponent - 1))\(digits)"
        }
        let whole = digits.count > exponent + 1
            ? String(digits.prefix(exponent + 1))
            : digits + String(repeating: "0", count: exponent + 1 - digits.count)
        let fraction = digits.count > exponent + 1 ? String(digits.dropFirst(exponent + 1)) : "0"
        return "\(sign)\(whole).\(fraction)"
    }
}
