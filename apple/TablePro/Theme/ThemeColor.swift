import AppKit
import TableProTheme

internal extension ThemeColor {
    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }

    // A color with no sRGB form, a pattern for one, becomes mid grey rather than failing.
    init(_ color: NSColor) {
        guard let converted = color.usingColorSpace(.sRGB) else {
            self.init(red: 0x80, green: 0x80, blue: 0x80)
            return
        }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: Self.byte(red), green: Self.byte(green), blue: Self.byte(blue), alpha: Self.byte(alpha))
    }

    private static func byte(_ component: CGFloat) -> UInt8 {
        UInt8(min(max((component * 255).rounded(), 0), 255))
    }
}

internal enum HexColor {
    internal static func string(from color: NSColor) -> String {
        ThemeColor(color).hex
    }

    internal static func color(_ hex: String) -> NSColor {
        ThemeColor(hex: hex)?.nsColor ?? .labelColor
    }
}

internal extension ThemeSlot {
    // A tint is built inside a provider: `withAlphaComponent` on a system color outside one freezes it.
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
        case .gridLine: return .separatorColor
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
    // macOS 14 draws the caret in the Highlight color; earlier releases in the text color.
    static let insertionPoint: NSColor = {
        if #available(macOS 14.0, *) {
            return .textInsertionPointColor
        }
        return .textColor
    }()

    // No system color exists for a current-line band; a faint accent follows Accent like the selection.
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
