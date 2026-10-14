import AppKit

/// Key, link and cluster hues carry meaning, so they stay system colors under a theme.
@MainActor
internal struct ERDiagramPalette {
    internal let appearance: NSAppearance
    internal let backdrop: CGColor
    internal let nodeFill: CGColor
    /// Nil keeps the accent wash a table header has always had.
    internal let headerFill: CGColor?
    internal let rule: CGColor
    internal let selectionRule: CGColor
    internal let edge: CGColor
    internal let text: NSColor
    internal let headerText: NSColor
    internal let secondaryText: NSColor

    private let accentWash: CGColor
    private let clusterWashes: [NSColor: CGColor]

    private static let accentWashAlpha: CGFloat = 0.15
    private static let clusterWashAlpha: CGFloat = 0.22
    private static let edgeAlpha: CGFloat = 0.7

    internal init(appearance: NSAppearance) {
        self.appearance = appearance
        let theme = ThemeEngine.shared.pair[ThemeAppearance(matching: appearance)]

        func color(_ slot: ThemeSlot, otherwise native: NSColor) -> NSColor {
            theme.isOverridden(slot, in: appearance) ? theme.color(for: slot) : native
        }

        backdrop = Self.bake(color(.windowBackdrop, otherwise: .controlBackgroundColor), in: appearance)
        nodeFill = Self.bake(color(.gridBackground, otherwise: .controlBackgroundColor), in: appearance)
        headerFill = theme.isOverridden(.gridHeaderBackground, in: appearance)
            ? Self.bake(theme.color(for: .gridHeaderBackground), in: appearance)
            : nil
        rule = Self.bake(color(.gridLine, otherwise: .tertiaryLabelColor), in: appearance)
        // The grid outlines its own selection with the focus border, not the row fill.
        selectionRule = Self.bake(color(.gridFocusBorder, otherwise: .controlAccentColor), in: appearance)
        edge = Self.wash(.secondaryLabelColor, alpha: Self.edgeAlpha, in: appearance)
        text = color(.gridText, otherwise: .labelColor)
        headerText = color(.gridHeaderText, otherwise: .labelColor)
        secondaryText = .secondaryLabelColor

        accentWash = Self.wash(.controlAccentColor, alpha: Self.accentWashAlpha, in: appearance)
        var washes: [NSColor: CGColor] = [:]
        for cluster in ERClusterPalette.colors {
            washes[cluster] = Self.wash(cluster, alpha: Self.clusterWashAlpha, in: appearance)
        }
        clusterWashes = washes
    }

    internal func headerWash(cluster: NSColor?) -> CGColor {
        guard let cluster else { return accentWash }
        return clusterWashes[cluster] ?? Self.wash(cluster, alpha: Self.clusterWashAlpha, in: appearance)
    }

    private static func bake(_ color: NSColor, in appearance: NSAppearance) -> CGColor {
        var result: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            result = color.cgColor
        }
        return result ?? color.cgColor
    }

    /// The alpha goes on the resolved color, so the system color itself is never frozen.
    private static func wash(_ color: NSColor, alpha: CGFloat, in appearance: NSAppearance) -> CGColor {
        let resolved = bake(color, in: appearance)
        return resolved.copy(alpha: alpha) ?? resolved
    }
}
