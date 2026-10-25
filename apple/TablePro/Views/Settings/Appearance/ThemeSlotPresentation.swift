import AppKit
import TableProTheme

// Text, not color alone, tells a set slot from one that follows the system.
internal struct ThemeSlotPresentation: Equatable {
    internal let slot: ThemeSlot
    internal let hasExplicitColor: Bool
    internal let displayColor: ThemeColor
    internal let stateLine: String
    internal let resetTitle: String
    internal let resetAccessibilityLabel: String

    internal init(slot: ThemeSlot, theme: ThemeDefinition) {
        self.slot = slot
        hasExplicitColor = theme.hasExplicitColor(slot)
        displayColor = Self.displayColor(for: slot, in: theme)
        stateLine = Self.stateLine(for: slot, in: theme)
        resetTitle = Self.resetTitle(for: slot, in: theme)
        resetAccessibilityLabel = Self.resetsToSystem(slot, in: theme)
            ? String(format: String(localized: "Use System Color for %@"), slot.accessibilityLabel)
            : String(format: String(localized: "Use Default Color for %@"), slot.accessibilityLabel)
    }

    // An unset slot shows the system color in the theme's own appearance, not the editor window's.
    internal static func displayColor(for slot: ThemeSlot, in theme: ThemeDefinition) -> ThemeColor {
        switch theme.value(for: slot) {
        case let .themed(color):
            return color
        case let .defaultSyntax(source):
            return DefaultSyntaxPalette.color(for: source, appearance: theme.appearance, highContrast: false)
                ?? resolved(source.nativeColor, in: theme.appearance)
        case let .system(source):
            return resolved(source.nativeColor, in: theme.appearance)
        }
    }

    internal static func stateLine(for slot: ThemeSlot, in theme: ThemeDefinition) -> String {
        if let explicit = theme.overrides[slot] {
            return explicit.hex
        }
        switch theme.value(for: slot) {
        case .system:
            return String(localized: "System color")
        case .defaultSyntax:
            switch theme.appearance {
            case .light: return String(localized: "Default Light color")
            case .dark: return String(localized: "Default Dark color")
            }
        case .themed:
            guard let source = slot.fallbackSource else { return String(localized: "System color") }
            return String(format: String(localized: "Based on %@"), source.accessibilityLabel)
        }
    }

    internal static func resetTitle(for slot: ThemeSlot, in theme: ThemeDefinition) -> String {
        resetsToSystem(slot, in: theme)
            ? String(localized: "Use System Color")
            : String(localized: "Use Default Color")
    }

    private static func resetsToSystem(_ slot: ThemeSlot, in theme: ThemeDefinition) -> Bool {
        var cleared = theme
        cleared.overrides[slot] = nil
        if case .system = cleared.value(for: slot) {
            return true
        }
        return false
    }

    private static func resolved(_ color: NSColor, in appearance: ThemeAppearance) -> ThemeColor {
        guard let drawing = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua) else {
            return ThemeColor(color)
        }
        var result = ThemeColor(color)
        drawing.performAsCurrentDrawingAppearance {
            result = ThemeColor(color.usingColorSpace(.sRGB) ?? color)
        }
        return result
    }
}

internal enum ThemeContrastNote {
    internal static let minimumRatio = 4.5

    internal static func pair(for section: ThemeSlotSection) -> (text: ThemeSlot, background: ThemeSlot)? {
        switch section {
        case .editor: return (.editorText, .editorBackground)
        case .dataGrid: return (.gridText, .gridBackground)
        case .window, .syntax, .changes: return nil
        }
    }

    internal static func ratio(for section: ThemeSlotSection, in theme: ThemeDefinition) -> Double? {
        guard let pair = pair(for: section) else { return nil }
        let background = ThemeSlotPresentation.displayColor(for: pair.background, in: theme).opaque
        let text = ThemeSlotPresentation.displayColor(for: pair.text, in: theme).composited(over: background)
        return text.contrastRatio(with: background)
    }

    internal static func message(for section: ThemeSlotSection, in theme: ThemeDefinition) -> String? {
        guard let ratio = ratio(for: section, in: theme), ratio < minimumRatio else { return nil }
        let formatted = ratio.formatted(.number.precision(.fractionLength(1)))
        return String(format: String(localized: "Text contrast is %@:1. Aim for at least 4.5:1."), formatted)
    }
}

private extension ThemeSlot {
    var fallbackSource: ThemeSlot? {
        switch fallback {
        case .system, .defaultSyntax: return nil
        case let .slot(source): return source
        case let .derived(base, _): return base
        }
    }
}
