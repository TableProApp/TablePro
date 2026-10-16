import Foundation

// VS Code takes the base theme from the extension's package.json `uiTheme`, which a lone theme file
// does not carry. A `type` key, which "Generate Color Theme From Current Settings" writes, is the
// best hint, then the editor background's luminance, then VS Code's own default, dark.
internal enum VSCodeThemeType: Equatable, Sendable {
    case light
    case dark
    case highContrastLight
    case highContrastDark

    // The point where a background contrasts equally with black and white text.
    private static let lightLuminanceThreshold = 0.179

    internal init?(name: String) {
        switch name.lowercased() {
        case "light", "vs": self = .light
        case "dark", "vs-dark": self = .dark
        case "hclight", "hc-light": self = .highContrastLight
        case "hcdark", "hc", "hc-black": self = .highContrastDark
        default: return nil
        }
    }

    internal init(typeName: String?, editorBackground: ThemeColor?) {
        if let typeName, let named = VSCodeThemeType(name: typeName) {
            self = named
        } else if let editorBackground {
            self = editorBackground.relativeLuminance > Self.lightLuminanceThreshold ? .light : .dark
        } else {
            self = .dark
        }
    }

    internal var appearance: ThemeAppearance {
        switch self {
        case .light, .highContrastLight: return .light
        case .dark, .highContrastDark: return .dark
        }
    }

    // colorRegistry `editor.background` defaults: what a translucent editor background sits on.
    internal var defaultEditorBackground: ThemeColor {
        switch self {
        case .light, .highContrastLight: return .white
        case .dark: return ThemeColor(red: 0x1E, green: 0x1E, blue: 0x1E)
        case .highContrastDark: return .black
        }
    }

    // colorRegistry `editor.foreground` defaults: the token color a theme without one paints.
    internal var defaultEditorForeground: ThemeColor {
        switch self {
        case .light: return ThemeColor(red: 0x33, green: 0x33, blue: 0x33)
        case .dark: return ThemeColor(red: 0xBB, green: 0xBB, blue: 0xBB)
        case .highContrastLight: return ThemeColor(red: 0x29, green: 0x29, blue: 0x29)
        case .highContrastDark: return .white
        }
    }
}
