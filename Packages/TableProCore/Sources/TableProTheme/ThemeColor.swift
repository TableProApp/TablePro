import Foundation

/// One color a theme declares, as 8-bit sRGB with alpha. It is a fixed value by design: a theme that
/// wants the system color leaves the slot out.
public struct ThemeColor: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public static let black = ThemeColor(red: 0, green: 0, blue: 0)
    public static let white = ThemeColor(red: 255, green: 255, blue: 255)

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#RRGGBB` or `#RRGGBBAA` and nothing else. Only ASCII digits: `Character.isHexDigit` is also
    /// true for the fullwidth forms.
    public init?(hex raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Array(trimmed.utf8)
        guard bytes.first == UInt8(ascii: "#"), bytes.count == 7 || bytes.count == 9 else { return nil }

        var channels: [UInt8] = []
        var index = 1
        while index < bytes.count {
            guard let high = Self.nibble(bytes[index]), let low = Self.nibble(bytes[index + 1]) else { return nil }
            channels.append(high << 4 | low)
            index += 2
        }
        self.init(red: channels[0], green: channels[1], blue: channels[2], alpha: channels.count == 4 ? channels[3] : 255)
    }

    public init(validating raw: String) throws {
        guard let color = ThemeColor(hex: raw) else { throw ThemeLoadError.invalidColor(raw) }
        self = color
    }

    /// Uppercase, and six digits whenever the color is opaque, so one color has one spelling.
    public var hex: String {
        let rgb = Self.hexDigits(red) + Self.hexDigits(green) + Self.hexDigits(blue)
        return "#" + (isOpaque ? rgb : rgb + Self.hexDigits(alpha))
    }

    public var isOpaque: Bool {
        alpha == 255
    }

    public var opaque: ThemeColor {
        ThemeColor(red: red, green: green, blue: blue)
    }

    /// Source-over in sRGB, the way a translucent fill lands on what is under it.
    public func composited(over base: ThemeColor) -> ThemeColor {
        let sourceAlpha = Double(alpha) / 255
        let baseAlpha = Double(base.alpha) / 255
        let resultAlpha = sourceAlpha + baseAlpha * (1 - sourceAlpha)
        guard resultAlpha > 0 else { return ThemeColor(red: 0, green: 0, blue: 0, alpha: 0) }

        func channel(_ source: UInt8, _ under: UInt8) -> UInt8 {
            let value = (Double(source) * sourceAlpha + Double(under) * baseAlpha * (1 - sourceAlpha)) / resultAlpha
            return Self.byte(value)
        }
        return ThemeColor(
            red: channel(red, base.red),
            green: channel(green, base.green),
            blue: channel(blue, base.blue),
            alpha: base.isOpaque ? 255 : Self.byte(resultAlpha * 255)
        )
    }

    /// Each color component moved `fraction` of the way toward `other`. The alpha stays this color's.
    public func mixed(with other: ThemeColor, fraction: Double) -> ThemeColor {
        let amount = min(max(fraction, 0), 1)
        func channel(_ from: UInt8, _ to: UInt8) -> UInt8 {
            Self.byte(Double(from) + (Double(to) - Double(from)) * amount)
        }
        return ThemeColor(
            red: channel(red, other.red),
            green: channel(green, other.green),
            blue: channel(blue, other.blue),
            alpha: alpha
        )
    }

    /// WCAG 2.x relative luminance of the color components. Alpha is ignored: composite first.
    public var relativeLuminance: Double {
        func linear(_ component: UInt8) -> Double {
            let value = Double(component) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2.x contrast ratio, from 1 to 21, the same whichever color is first.
    public func contrastRatio(with other: ThemeColor) -> Double {
        let first = relativeLuminance
        let second = other.relativeLuminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        default: return nil
        }
    }

    private static func hexDigits(_ value: UInt8) -> String {
        let digits = Array("0123456789ABCDEF")
        return String([digits[Int(value >> 4)], digits[Int(value & 0x0F)]])
    }

    private static func byte(_ value: Double) -> UInt8 {
        UInt8(min(max(value.rounded(), 0), 255))
    }
}

extension ThemeColor: CustomStringConvertible {
    public var description: String {
        hex
    }
}
