import Foundation

public enum ExactNumberFormat {
    public static let maximumFractionDigits = 15

    private static let scientificSignificantDigits = 15
    /// Past this many integer digits an approximation would print digits a `Double` does not hold.
    private static let approximateIntegerDigits = 15
    private static let posix = Locale(identifier: "en_US_POSIX")

    private enum Rendering {
        case plain(DecimalDigits, fractionDigits: Int)
        case scientific(DecimalDigits)
    }

    public static func string(_ number: ExactNumber, fractionDigits: ClosedRange<Int>, locale: Locale) -> String {
        let prefix = number.isApproximate ? "≈ " : ""
        guard let rendering = rendering(of: number, fractionDigits: fractionDigits) else {
            return prefix + number.approximation.formatted(FloatingPointFormatStyle<Double>(locale: locale))
        }
        switch rendering {
        case .plain(let value, let shown):
            guard let decimal = Decimal(string: value.exponentText, locale: posix) else {
                return prefix + value.plainText(fractionDigits: shown)
            }
            let style = Decimal.FormatStyle(locale: locale).precision(.fractionLength(shown...shown))
            return prefix + decimal.formatted(style)
        case .scientific(let value):
            // Rounding to 15 digits can carry past `Double.greatestFiniteMagnitude`; the unrounded
            // value then stays finite and the style does the same rounding.
            let rounded = value.rounded(significantDigits: scientificSignificantDigits).doubleValue
            let style = FloatingPointFormatStyle<Double>(locale: locale)
                .notation(.scientific)
                .precision(.significantDigits(1...scientificSignificantDigits))
                .rounded(rule: .toNearestOrAwayFromZero)
            return prefix + (rounded.isFinite ? rounded : value.doubleValue).formatted(style)
        }
    }

    public static func plainText(_ number: ExactNumber, fractionDigits: ClosedRange<Int>) -> String {
        guard let rendering = rendering(of: number, fractionDigits: fractionDigits) else {
            return number.approximation.description
        }
        switch rendering {
        case .plain(let value, let shown):
            return value.plainText(fractionDigits: shown)
        case .scientific(let value):
            return value.scientificText
        }
    }

    /// Rounds to the upper bound first; scientific notation is chosen by the digits that are left,
    /// so a scale padded past the limit (DECIMAL(65,30)) still prints plain.
    private static func rendering(of number: ExactNumber, fractionDigits: ClosedRange<Int>) -> Rendering? {
        let value: DecimalDigits
        if let decimal = number.decimal {
            value = DecimalDigits(decimal: decimal)
        } else if let approximation = DecimalDigits(double: number.approximation) {
            value = approximation
        } else {
            return nil
        }
        let rounded = value.rounded(fractionDigits: max(0, fractionDigits.upperBound))
        let padding = number.isApproximate ? 0 : min(max(0, fractionDigits.lowerBound), maximumFractionDigits)
        let shown = max(padding, rounded.fractionDigitCount)
        let isLargeApproximation = number.isApproximate && rounded.leadingPosition > approximateIntegerDigits
        guard shown <= maximumFractionDigits, !isLargeApproximation else {
            return .scientific(rounded)
        }
        return .plain(rounded, fractionDigits: shown)
    }
}
