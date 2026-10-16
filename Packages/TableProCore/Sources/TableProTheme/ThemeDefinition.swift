import Foundation

/// A theme is a set of colors for the content views and the window backdrop. A slot it leaves out
/// draws what its `ThemeSlot.fallback` says, so Default Light and Default Dark declare nothing and
/// render exactly like a native app, following Accent, Highlight and Increase Contrast.
public struct ThemeDefinition: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var author: String
    public var appearance: ThemeAppearance
    public var overrides: [ThemeSlot: ThemeColor]

    public static let builtInPrefix = "tablepro."
    public static let userPrefix = "user."

    public init(
        id: String,
        name: String,
        author: String,
        appearance: ThemeAppearance,
        overrides: [ThemeSlot: ThemeColor]
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.appearance = appearance
        self.overrides = overrides
    }

    public var isBuiltIn: Bool {
        id.hasPrefix(Self.builtInPrefix)
    }

    public var isEditable: Bool {
        !isBuiltIn
    }

    /// The file sets this slot. Only the theme editor asks: a derived slot draws a theme color the
    /// file never wrote, and an explicit selection text draws nothing without a selection.
    public func hasExplicitColor(_ slot: ThemeSlot) -> Bool {
        overrides[slot] != nil
    }

    /// The format has no increased-contrast variant, so a slot that yields to Increase Contrast draws
    /// native there even where the theme sets it.
    public func value(for slot: ThemeSlot, highContrast: Bool = false) -> ThemeSlotValue {
        if slot.yieldsToIncreasedContrast, highContrast {
            return .system(slot)
        }
        if let explicit = overrides[slot], allowsExplicitColor(for: slot, highContrast: highContrast) {
            return .themed(slot.requiresOpaque ? explicit.opaque : explicit)
        }
        return fallbackValue(for: slot, highContrast: highContrast)
    }

    /// The slot draws a theme color, set or derived. Every surface that swaps a native drawing path
    /// for the theme's asks this.
    public func isOverridden(_ slot: ThemeSlot, highContrast: Bool) -> Bool {
        value(for: slot, highContrast: highContrast).isThemed
    }

    public func isOverridden(_ slot: ThemeSlot) -> Bool {
        isOverridden(slot, highContrast: false)
    }

    private func allowsExplicitColor(for slot: ThemeSlot, highContrast: Bool) -> Bool {
        guard case let .paired(partner, _) = slot.fallback else { return true }
        return value(for: partner, highContrast: highContrast).isThemed
    }

    private func fallbackValue(for slot: ThemeSlot, highContrast: Bool) -> ThemeSlotValue {
        switch slot.fallback {
        case .system:
            return .system(slot)
        case .defaultSyntax:
            return .defaultSyntax(slot)
        case let .slot(source):
            guard let color = value(for: source, highContrast: highContrast).themedColor else { return .system(slot) }
            return .themed(color)
        case let .derived(base, rule):
            guard let baseColor = value(for: base, highContrast: highContrast).themedColor else { return .system(slot) }
            return .themed(derive(rule, from: baseColor, highContrast: highContrast))
        case let .paired(partner, fallback):
            guard value(for: partner, highContrast: highContrast).isThemed else { return .system(slot) }
            return value(for: fallback, highContrast: highContrast)
        }
    }

    private func derive(_ rule: ThemeDerivationRule, from base: ThemeColor, highContrast: Bool) -> ThemeColor {
        switch rule {
        case .same:
            return base
        case let .stripe(toward):
            let target = value(for: toward, highContrast: highContrast).themedColor
                ?? (appearance == .dark ? .white : .black)
            return base.mixed(with: target, fraction: ThemeDerivationRule.stripeFraction).opaque
        }
    }
}
