import AppKit
import SwiftUI

internal enum SystemColorName: String, Codable, CaseIterable, Sendable {
    case label
    case secondaryLabel
    case tertiaryLabel
    case quaternaryLabel
    case text
    case textBackground
    case selectedText
    case selectedTextBackground
    case placeholderText
    case disabledControlText
    case controlBackground
    case windowBackground
    case underPageBackground
    case separator
    case grid
    case selectedContentBackground
    case unemphasizedSelectedContentBackground
    case alternateSelectedControlText
    case controlAccent
    case keyboardFocusIndicator
    case alternatingContentBackgroundEven
    case alternatingContentBackgroundOdd
    case systemRed
    case systemGreen
    case systemBlue
    case systemOrange
    case systemYellow
    case systemPurple
    case systemTeal
    case systemGray

    internal var color: NSColor {
        switch self {
        case .label: return .labelColor
        case .secondaryLabel: return .secondaryLabelColor
        case .tertiaryLabel: return .tertiaryLabelColor
        case .quaternaryLabel: return .quaternaryLabelColor
        case .text: return .textColor
        case .textBackground: return .textBackgroundColor
        case .selectedText: return .selectedTextColor
        case .selectedTextBackground: return .selectedTextBackgroundColor
        case .placeholderText: return .placeholderTextColor
        case .disabledControlText: return .disabledControlTextColor
        case .controlBackground: return .controlBackgroundColor
        case .windowBackground: return .windowBackgroundColor
        case .underPageBackground: return .underPageBackgroundColor
        case .separator: return .separatorColor
        case .grid: return .gridColor
        case .selectedContentBackground: return .selectedContentBackgroundColor
        case .unemphasizedSelectedContentBackground: return .unemphasizedSelectedContentBackgroundColor
        case .alternateSelectedControlText: return .alternateSelectedControlTextColor
        case .controlAccent: return .controlAccentColor
        case .keyboardFocusIndicator: return .keyboardFocusIndicatorColor
        case .alternatingContentBackgroundEven: return Self.alternatingContentBackground(at: 0)
        case .alternatingContentBackgroundOdd: return Self.alternatingContentBackground(at: 1)
        case .systemRed: return .systemRed
        case .systemGreen: return .systemGreen
        case .systemBlue: return .systemBlue
        case .systemOrange: return .systemOrange
        case .systemYellow: return .systemYellow
        case .systemPurple: return .systemPurple
        case .systemTeal: return .systemTeal
        case .systemGray: return .systemGray
        }
    }

    private static func alternatingContentBackground(at index: Int) -> NSColor {
        let colors = NSColor.alternatingContentBackgroundColors
        guard colors.indices.contains(index) else { return .controlBackgroundColor }
        return colors[index]
    }
}

/// A theme slot's value. `system` keeps a slot on the AppKit semantic colour its call site used
/// before the theme owned it, so the built-in themes stay pixel-identical to the unthemed app and
/// keep the system's own Increase Contrast and vibrancy adaptations. A custom theme uses `hex`.
internal enum ThemeColorValue: Equatable, Hashable, Sendable {
    case hex(String)
    case system(SystemColorName)

    internal static let systemPrefix = "system:"

    internal init(validating raw: String) throws {
        if raw.hasPrefix(Self.systemPrefix) {
            let name = String(raw.dropFirst(Self.systemPrefix.count))
            guard let known = SystemColorName(rawValue: name) else {
                throw ThemeLoadError.unknownSystemColor(name)
            }
            self = .system(known)
            return
        }

        guard let canonical = HexColor.canonicalize(raw) else {
            throw ThemeLoadError.invalidColor(raw)
        }
        self = .hex(canonical)
    }

    internal var rawValue: String {
        switch self {
        case let .hex(value): return value
        case let .system(name): return Self.systemPrefix + name.rawValue
        }
    }

    internal var nsColor: NSColor {
        switch self {
        case let .hex(value): return HexColor.color(value)
        case let .system(name): return name.color
        }
    }

    internal var swiftUIColor: Color {
        Color(nsColor: nsColor)
    }

    internal var isSystem: Bool {
        if case .system = self { return true }
        return false
    }
}

extension ThemeColorValue: Codable {
    internal init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        try self.init(validating: raw)
    }

    internal func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The parser rejects any string it does not consume whole. The previous one asked only whether
/// `Scanner.scanHexInt64` succeeded, which it does on a valid prefix, so `#FF79CG` silently
/// rendered as `#0FF79C` instead of reporting a typo.
internal enum HexColor {
    internal static func canonicalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }

        let digits = trimmed.dropFirst()
        guard digits.count == 6 || digits.count == 8 else { return nil }
        guard digits.allSatisfy(\.isHexDigit) else { return nil }

        return "#" + digits.uppercased()
    }

    internal static func color(_ canonical: String) -> NSColor {
        let digits = canonical.dropFirst()
        var value: UInt64 = 0
        guard Scanner(string: String(digits)).scanHexInt64(&value) else { return .labelColor }

        if digits.count == 8 {
            return NSColor(
                srgbRed: CGFloat((value >> 24) & 0xFF) / 255,
                green: CGFloat((value >> 16) & 0xFF) / 255,
                blue: CGFloat((value >> 8) & 0xFF) / 255,
                alpha: CGFloat(value & 0xFF) / 255
            )
        }

        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    internal static func string(from color: NSColor) -> String {
        guard let converted = color.usingColorSpace(.sRGB) else { return "#808080" }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let redValue = Int(round(red * 255))
        let greenValue = Int(round(green * 255))
        let blueValue = Int(round(blue * 255))

        guard alpha < 1 else {
            return String(format: "#%02X%02X%02X", redValue, greenValue, blueValue)
        }
        return String(format: "#%02X%02X%02X%02X", redValue, greenValue, blueValue, Int(round(alpha * 255)))
    }
}
