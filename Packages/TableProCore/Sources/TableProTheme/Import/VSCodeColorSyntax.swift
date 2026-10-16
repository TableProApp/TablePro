import Foundation

// VS Code writes `#RGB`, `#RGBA`, `#RRGGBB` and `#RRGGBBAA`; the TablePro format only the long forms.
internal enum VSCodeColorSyntax {
    // colorThemeData.ts normalizeColor: uppercase, short forms doubled, an FF alpha dropped.
    internal static func normalized(_ raw: String) -> String? {
        let digits = Array(raw.utf8.dropFirst())
        guard raw.utf8.first == UInt8(ascii: "#"), [3, 4, 6, 8].contains(digits.count) else { return nil }

        var result = "#"
        for byte in digits {
            guard let digit = uppercaseHexDigit(byte) else { return nil }
            result.append(digit)
            if digits.count <= 4 {
                result.append(digit)
            }
        }
        if result.utf8.count == 9, result.hasSuffix("FF") {
            result.removeLast(2)
        }
        return result
    }

    internal static func color(_ raw: String) -> ThemeColor? {
        normalized(raw).flatMap(ThemeColor.init(hex:))
    }

    // colorUtils.ts transparent(): the alpha scaled, the color kept.
    internal static func transparent(_ color: ThemeColor, factor: Double) -> ThemeColor {
        let alpha = (Double(color.alpha) * factor).rounded()
        return ThemeColor(red: color.red, green: color.green, blue: color.blue, alpha: UInt8(min(max(alpha, 0), 255)))
    }

    private static func uppercaseHexDigit(_ byte: UInt8) -> Character? {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "A") ... UInt8(ascii: "F"):
            return Character(Unicode.Scalar(byte))
        case UInt8(ascii: "a") ... UInt8(ascii: "f"):
            return Character(Unicode.Scalar(byte - 32))
        default:
            return nil
        }
    }
}
