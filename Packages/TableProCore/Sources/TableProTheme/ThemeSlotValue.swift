import Foundation

/// What a slot draws under a theme. Only `themed` is a fixed color; the other two are resolved by
/// the platform, so they keep following the system.
public enum ThemeSlotValue: Equatable, Sendable {
    case themed(ThemeColor)
    /// The native color of the slot named, which can be another slot than the one asked for.
    case system(ThemeSlot)
    /// The same-appearance default's syntax color, which has a high-contrast variant.
    case defaultSyntax(ThemeSlot)

    public var themedColor: ThemeColor? {
        guard case let .themed(color) = self else { return nil }
        return color
    }

    public var isThemed: Bool {
        themedColor != nil
    }
}
