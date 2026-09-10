//
//  JsonNumberNormalizer.swift
//  TableProPluginKit
//

import Foundation

/// Rewrites the numeric spellings drivers emit into RFC 8259 literals using text arithmetic.
///
/// Nothing here goes through `Double`, so a value wider than 53 significant bits keeps every digit
/// it arrived with. Both JSON writers, the results pane and the export plugin, share these rules so
/// the same row cannot serialize two different ways.
public enum JsonNumberNormalizer {
    static let maxExponentMagnitude = 1_000

    /// The exact integer `value` denotes, as a JSON integer literal, or nil when it denotes no
    /// integer. Accepts the decimal and exponent spellings drivers use for integral values
    /// (`42.0`, `1e3`, `1000e-3`) and rejects anything with a nonzero fractional part.
    public static func integerLiteral(from value: String) -> String? {
        NumericLiteral(value)?.integerLiteral()
    }

    /// `value` as a JSON number literal preserving every digit, or nil when it is not a number.
    /// Normalizes the spellings JSON rejects: a leading `+`, leading zeros, a bare leading or
    /// trailing decimal point.
    public static func numberLiteral(from value: String) -> String? {
        NumericLiteral(value)?.numberLiteral()
    }
}

private struct NumericLiteral {
    private static let zero = Unicode.Scalar("0")

    private let isNegative: Bool
    private let integerDigits: [Unicode.Scalar]
    private let fractionDigits: [Unicode.Scalar]
    private let exponent: Int?

    init?(_ value: String) {
        var iterator = value.unicodeScalars.makeIterator()
        var scalar = iterator.next()

        var negative = false
        if scalar == "-" || scalar == "+" {
            negative = scalar == "-"
            scalar = iterator.next()
        }

        var integerPart = [Unicode.Scalar]()
        while let digit = scalar, Self.isAsciiDigit(digit) {
            integerPart.append(digit)
            scalar = iterator.next()
        }

        var fractionPart = [Unicode.Scalar]()
        if scalar == "." {
            scalar = iterator.next()
            while let digit = scalar, Self.isAsciiDigit(digit) {
                fractionPart.append(digit)
                scalar = iterator.next()
            }
        }

        guard !integerPart.isEmpty || !fractionPart.isEmpty else { return nil }

        var parsedExponent: Int?
        if scalar == "e" || scalar == "E" {
            scalar = iterator.next()
            var exponentIsNegative = false
            if scalar == "-" || scalar == "+" {
                exponentIsNegative = scalar == "-"
                scalar = iterator.next()
            }
            var magnitude = 0
            var sawExponentDigit = false
            while let digit = scalar, Self.isAsciiDigit(digit) {
                guard magnitude <= JsonNumberNormalizer.maxExponentMagnitude else { return nil }
                magnitude = magnitude * 10 + Int(digit.value - Self.zero.value)
                sawExponentDigit = true
                scalar = iterator.next()
            }
            guard sawExponentDigit, magnitude <= JsonNumberNormalizer.maxExponentMagnitude else { return nil }
            parsedExponent = exponentIsNegative ? -magnitude : magnitude
        }

        guard scalar == nil else { return nil }

        isNegative = negative
        integerDigits = integerPart
        fractionDigits = fractionPart
        exponent = parsedExponent
    }

    func integerLiteral() -> String? {
        var digits = integerDigits + fractionDigits
        guard let firstSignificant = digits.firstIndex(where: { $0 != Self.zero }) else { return "0" }
        digits.removeFirst(firstSignificant)

        let scale = (exponent ?? 0) - fractionDigits.count
        if scale >= 0 {
            digits.append(contentsOf: repeatElement(Self.zero, count: scale))
        } else {
            let droppedCount = -scale
            guard droppedCount < digits.count,
                  digits.suffix(droppedCount).allSatisfy({ $0 == Self.zero }) else { return nil }
            digits.removeLast(droppedCount)
        }

        return (isNegative ? "-" : "") + Self.text(of: digits)
    }

    func numberLiteral() -> String {
        var text = isNegative ? "-" : ""
        if let firstSignificant = integerDigits.firstIndex(where: { $0 != Self.zero }) {
            text += Self.text(of: integerDigits[firstSignificant...])
        } else {
            text += "0"
        }
        if !fractionDigits.isEmpty {
            text += "." + Self.text(of: fractionDigits)
        }
        if let exponent {
            text += "e\(exponent)"
        }
        return text
    }

    private static func isAsciiDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x30 && scalar.value <= 0x39
    }

    private static func text(of digits: some Sequence<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(digits))
    }
}
