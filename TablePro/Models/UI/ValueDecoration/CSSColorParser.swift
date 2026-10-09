//
//  CSSColorParser.swift
//  TablePro
//

import Foundation

/// No `#RGBA` and no named colors: `#2024`, `#beef` and `tan` are ordinary values far more often
/// than they are colors.
internal enum CSSColorParser {
    static let maxLength = 64

    static func parse(_ raw: String) -> RGBAColor? {
        guard raw.utf8.count(isAtMost: maxLength) else { return nil }
        var cursor = Cursor(raw.unicodeScalars.map(\.asciiLowercased))
        if cursor.skip("#") { return hexColor(cursor.rest) }
        switch cursor.word() {
        case "rgb", "rgba": return rgbColor(&cursor)
        case "hsl", "hsla": return hslColor(&cursor)
        default: return nil
        }
    }
}

private extension CSSColorParser {
    struct Component {
        let value: Double
        let isPercentage: Bool
    }

    struct Arguments {
        let first: Component
        let second: Component
        let third: Component
        let alpha: Double
        let usesCommas: Bool
    }

    static func hexColor(_ digits: ArraySlice<Unicode.Scalar>) -> RGBAColor? {
        var nibbles: [Int] = []
        for digit in digits {
            /// `hexDigitValue` also reads the fullwidth digits.
            guard digit.isASCII, let value = Character(digit).hexDigitValue else { return nil }
            nibbles.append(value)
        }
        if nibbles.count == 3 { nibbles = nibbles.flatMap { [$0, $0] } }
        guard nibbles.count == 6 || nibbles.count == 8 else { return nil }
        let channels = stride(from: 0, to: nibbles.count, by: 2).map { Double(nibbles[$0] * 16 + nibbles[$0 + 1]) / 255 }
        return RGBAColor(red: channels[0], green: channels[1], blue: channels[2], alpha: channels.count == 4 ? channels[3] : 1)
    }

    static func rgbColor(_ cursor: inout Cursor) -> RGBAColor? {
        guard let arguments = arguments(&cursor, startsWithHue: false) else { return nil }
        /// The comma syntax takes three numbers or three percentages. Only the space syntax mixes.
        let isMixed = arguments.first.isPercentage != arguments.second.isPercentage
            || arguments.second.isPercentage != arguments.third.isPercentage
        guard !(arguments.usesCommas && isMixed) else { return nil }
        func channel(_ component: Component) -> Double {
            clamped(component.value / (component.isPercentage ? 100 : 255))
        }
        return RGBAColor(
            red: channel(arguments.first),
            green: channel(arguments.second),
            blue: channel(arguments.third),
            alpha: arguments.alpha
        )
    }

    static func hslColor(_ cursor: inout Cursor) -> RGBAColor? {
        guard let arguments = arguments(&cursor, startsWithHue: true) else { return nil }
        /// The comma syntax takes saturation and lightness as percentages. The space syntax also
        /// takes a bare number, on the same 0 to 100 scale.
        let arePercentages = arguments.second.isPercentage && arguments.third.isPercentage
        guard arePercentages || !arguments.usesCommas else { return nil }
        return rgba(
            hue: arguments.first.value,
            saturation: clamped(arguments.second.value / 100),
            lightness: clamped(arguments.third.value / 100),
            alpha: arguments.alpha
        )
    }

    static func arguments(_ cursor: inout Cursor, startsWithHue: Bool) -> Arguments? {
        guard cursor.skip("(") else { return nil }
        cursor.skipSpaces()
        guard let first = startsWithHue ? cursor.hue() : cursor.component() else { return nil }
        let hadSpace = cursor.skipSpaces()
        let usesCommas = cursor.skip(",")
        guard usesCommas || hadSpace else { return nil }
        cursor.skipSpaces()
        guard let second = cursor.component(),
              cursor.skipSeparator(comma: usesCommas),
              let third = cursor.component() else { return nil }
        cursor.skipSpaces()
        var alpha = 1.0
        if cursor.skip(usesCommas ? "," : "/") {
            cursor.skipSpaces()
            guard let component = cursor.component() else { return nil }
            alpha = clamped(component.value / (component.isPercentage ? 100 : 1))
            cursor.skipSpaces()
        }
        guard cursor.skip(")"), cursor.isAtEnd else { return nil }
        return Arguments(first: first, second: second, third: third, alpha: alpha, usesCommas: usesCommas)
    }

    /// The CSS Color 4 conversion. `NSColor(hue:saturation:brightness:alpha:)` is HSB, another
    /// model: it turns `hsl(32, 100%, 50%)` into a dark brown.
    static func rgba(hue: Double, saturation: Double, lightness: Double, alpha: Double) -> RGBAColor {
        let degrees = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let amplitude = saturation * min(lightness, 1 - lightness)
        func channel(_ offset: Double) -> Double {
            let sector = (offset + degrees / 30).truncatingRemainder(dividingBy: 12)
            return clamped(lightness - amplitude * max(-1, min(sector - 3, 9 - sector, 1)))
        }
        return RGBAColor(red: channel(0), green: channel(8), blue: channel(4), alpha: alpha)
    }

    static func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    struct Cursor {
        private let scalars: [Unicode.Scalar]
        private var position = 0

        init(_ scalars: [Unicode.Scalar]) {
            self.scalars = scalars
        }

        var isAtEnd: Bool {
            position == scalars.count
        }

        var rest: ArraySlice<Unicode.Scalar> {
            scalars[position...]
        }

        @discardableResult
        mutating func skip(_ scalar: Unicode.Scalar) -> Bool {
            guard position < scalars.count, scalars[position] == scalar else { return false }
            position += 1
            return true
        }

        @discardableResult
        mutating func skipSpaces() -> Bool {
            advance { $0 == " " } > 0
        }

        mutating func skipSeparator(comma: Bool) -> Bool {
            let hadSpace = skipSpaces()
            guard comma else { return hadSpace }
            guard skip(",") else { return false }
            skipSpaces()
            return true
        }

        mutating func word() -> String {
            let start = position
            advance { ("a"..."z").contains($0) }
            return text(from: start)
        }

        mutating func component() -> Component? {
            guard let value = number() else { return nil }
            return Component(value: value, isPercentage: skip("%"))
        }

        mutating func hue() -> Component? {
            guard let value = number() else { return nil }
            let degreesPerUnit: Double
            switch word() {
            case "", "deg": degreesPerUnit = 1
            case "grad": degreesPerUnit = 0.9
            case "rad": degreesPerUnit = 180 / .pi
            case "turn": degreesPerUnit = 360
            default: return nil
            }
            return Component(value: value * degreesPerUnit, isPercentage: false)
        }

        /// `Double(_:)` also reads `nan`, `inf`, `0x1p3`, `1e5` and `1.`, so the token is matched
        /// here and only then converted. A token with no digit in it converts to nil.
        private mutating func number() -> Double? {
            let start = position
            if !skip("-") { skip("+") }
            advance(while: Self.isDigit)
            if position + 1 < scalars.count, scalars[position] == ".", Self.isDigit(scalars[position + 1]) {
                position += 1
                advance(while: Self.isDigit)
            }
            return Double(text(from: start))
        }

        @discardableResult
        private mutating func advance(while matches: (Unicode.Scalar) -> Bool) -> Int {
            let start = position
            while position < scalars.count, matches(scalars[position]) { position += 1 }
            return position - start
        }

        private func text(from start: Int) -> String {
            String(String.UnicodeScalarView(scalars[start..<position]))
        }

        private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
            ("0"..."9").contains(scalar)
        }
    }
}
