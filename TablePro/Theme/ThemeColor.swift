import AppKit
import SwiftUI

/// One color a theme declares, held as canonical `#RRGGBB` or `#RRGGBBAA` in sRGB. It is a fixed
/// value by design: a theme that wants the system color leaves the slot out.
internal struct ThemeColor: Hashable, Sendable {
    internal let hex: String
    internal let nsColor: NSColor

    internal init(validating raw: String) throws {
        guard let canonical = HexColor.canonicalize(raw) else {
            throw ThemeLoadError.invalidColor(raw)
        }
        hex = canonical
        nsColor = HexColor.color(canonical)
    }

    internal init(_ color: NSColor) {
        hex = HexColor.string(from: color)
        nsColor = HexColor.color(hex)
    }

    internal static func == (lhs: ThemeColor, rhs: ThemeColor) -> Bool {
        lhs.hex == rhs.hex
    }

    internal func hash(into hasher: inout Hasher) {
        hasher.combine(hex)
    }

    internal var swiftUIColor: Color {
        Color(nsColor: nsColor)
    }
}

/// The parser rejects any string it does not consume whole, and only ASCII hex digits:
/// `Character.isHexDigit` is also true for the fullwidth forms, which `Scanner` then refuses.
internal enum HexColor {
    private static let digits = Set("0123456789ABCDEFabcdef")

    internal static func canonicalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }

        let body = trimmed.dropFirst()
        guard body.count == 6 || body.count == 8 else { return nil }
        guard body.allSatisfy({ digits.contains($0) }) else { return nil }

        return "#" + body.uppercased()
    }

    internal static func color(_ canonical: String) -> NSColor {
        let body = canonical.dropFirst()
        var value: UInt64 = 0
        guard Scanner(string: String(body)).scanHexInt64(&value) else { return .labelColor }

        if body.count == 8 {
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

internal extension ThemeSlot {
    /// What the slot draws when no theme overrides it: the color AppKit itself uses on that
    /// surface. Every value is dynamic, so it resolves against the drawing view's own appearance,
    /// accent, highlight and contrast. A tint is built inside a provider, because
    /// `withAlphaComponent` on a system color outside one freezes it at the current appearance.
    var nativeColor: NSColor {
        switch self {
        case .windowBackdrop: return .windowBackgroundColor

        case .editorBackground: return .textBackgroundColor
        case .editorText, .syntaxOperator: return .textColor
        case .editorCursor: return NativeThemeColors.insertionPoint
        case .editorSelection: return .selectedTextBackgroundColor
        case .editorCurrentLine: return NativeThemeColors.currentLine
        case .editorCurrentStatement: return .quinaryLabel
        case .editorLineNumber: return .secondaryLabelColor
        case .editorInvisibles: return .tertiaryLabelColor

        case .syntaxKeyword, .syntaxString, .syntaxNumber, .syntaxComment,
             .syntaxNull, .syntaxFunction, .syntaxType:
            return .textColor

        case .gridBackground: return .controlBackgroundColor
        case .gridText, .gridBoolTrue, .gridBoolFalse: return .labelColor
        case .gridAlternateRow: return NativeThemeColors.alternateRow
        case .gridHeaderBackground: return .controlBackgroundColor
        case .gridHeaderText: return .headerTextColor
        case .gridLine: return .separatorColor
        case .gridSelection: return .selectedContentBackgroundColor
        case .gridSelectionText: return .alternateSelectedControlTextColor
        case .gridInactiveSelection: return .unemphasizedSelectedContentBackgroundColor
        case .gridFocusBorder: return .keyboardFocusIndicatorColor
        case .gridNullValue: return .secondaryLabelColor
        case .gridRowNumber: return .secondaryLabelColor
        case .gridModified: return NativeThemeColors.modifiedRow
        case .gridInserted: return NativeThemeColors.insertedRow
        case .gridDeleted: return NativeThemeColors.deletedRow
        case .gridDeletedText: return NativeThemeColors.deletedText
        }
    }
}

internal enum NativeThemeColors {
    /// macOS 14 draws the caret in the Highlight color through `textInsertionPointColor`. Earlier
    /// releases draw it in the text color.
    static let insertionPoint: NSColor = {
        if #available(macOS 14.0, *) {
            return .textInsertionPointColor
        }
        return .textColor
    }()

    /// No system color exists for a current-line band; a faint accent keeps it on the user's
    /// Accent color the way the selection and focus ring are.
    static let currentLine = NSColor(name: NSColor.Name("tablepro.native.currentLine")) { appearance in
        NSColor.controlAccentColor.withAlphaComponent(appearance.isDarkTheme ? 0.14 : 0.08)
    }

    static let alternateRow = NSColor(name: NSColor.Name("tablepro.native.alternateRow")) { _ in
        let colors = NSColor.alternatingContentBackgroundColors
        return colors.count > 1 ? colors[1] : .controlBackgroundColor
    }

    static let modifiedRow = NSColor(name: NSColor.Name("tablepro.native.modifiedRow")) { _ in
        NSColor.systemYellow.withAlphaComponent(0.3)
    }

    static let insertedRow = NSColor(name: NSColor.Name("tablepro.native.insertedRow")) { appearance in
        NSColor.systemGreen.withAlphaComponent(appearance.isDarkTheme ? 0.15 : 0.3)
    }

    static let deletedRow = NSColor(name: NSColor.Name("tablepro.native.deletedRow")) { appearance in
        NSColor.systemRed.withAlphaComponent(appearance.isDarkTheme ? 0.15 : 0.3)
    }

    static let deletedText = NSColor(name: NSColor.Name("tablepro.native.deletedText")) { _ in
        NSColor.systemRed.withAlphaComponent(0.5)
    }
}

internal extension NSAppearance {
    var isDarkTheme: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    var isHighContrast: Bool {
        let match = bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ])
        return match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
    }
}
