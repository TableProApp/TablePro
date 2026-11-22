//
//  ConnectionTileView.swift
//  TablePro
//

import AppKit
import SwiftUI

// One set of numbers for the tile Welcome, the switcher and the rail draw, so the three agree.
internal enum ConnectionTileMetrics {
    internal static func cornerRadius(for size: CGFloat) -> CGFloat {
        size * 0.26
    }

    internal static func glyphSide(for size: CGFloat) -> CGFloat {
        size * 0.58
    }

    internal static func glyphPointSize(for size: CGFloat) -> CGFloat {
        size * 0.5
    }

    // Brand hues are picked for a white page, so several (PostgreSQL's blue, Kafka's near black) fail on the dark
    // tile. WCAG's 3:1 for a graphic was not enough: the engine marks are thin line art, and antialiasing blends
    // their strokes into the tile, so the elephant still vanished. They are lifted to the floor for text instead.
    internal static let minimumGlyphContrast: CGFloat = 4.5

    // The brand colour in Light Mode; in Dark Mode the same hue lifted until it clears the tile.
    internal static func glyphColor(brand: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            guard appearance.isDarkTheme else { return brand }
            var lifted = brand
            appearance.performAsCurrentDrawingAppearance {
                lifted = liftedGlyph(brand, onTileLuminance: tileLuminance())
            }
            return lifted
        }
    }

    // The tile as it draws: quaternaryLabelColor over the window background, in the current appearance.
    internal static func tileLuminance() -> CGFloat {
        guard let tile = NSColor.quaternaryLabelColor.usingColorSpace(.sRGB),
              let base = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
        else { return 0 }
        let alpha = tile.alphaComponent
        let composite = NSColor(
            srgbRed: tile.redComponent * alpha + base.redComponent * (1 - alpha),
            green: tile.greenComponent * alpha + base.greenComponent * (1 - alpha),
            blue: tile.blueComponent * alpha + base.blueComponent * (1 - alpha),
            alpha: 1
        )
        return composite.relativeLuminance
    }

    internal static func contrast(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    // Raises brightness first, which keeps hue and saturation; only a hue too dark at full brightness
    // (pure blue) also gives up saturation.
    internal static func liftedGlyph(_ color: NSColor, onTileLuminance tile: CGFloat) -> NSColor {
        guard let srgb = color.usingColorSpace(.sRGB) else { return color }
        func passes(_ candidate: NSColor) -> Bool {
            contrast(candidate.relativeLuminance, tile) >= minimumGlyphContrast
        }
        guard !passes(srgb) else { return color }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let bright = NSColor(hue: hue, saturation: saturation, brightness: 1, alpha: alpha)
        if passes(bright) {
            var failing = brightness
            var passing: CGFloat = 1
            for _ in 0 ..< liftSteps {
                let middle = (failing + passing) / 2
                if passes(NSColor(hue: hue, saturation: saturation, brightness: middle, alpha: alpha)) {
                    passing = middle
                } else {
                    failing = middle
                }
            }
            return NSColor(hue: hue, saturation: saturation, brightness: passing, alpha: alpha)
        }

        var passing: CGFloat = 0
        var failing = saturation
        for _ in 0 ..< liftSteps {
            let middle = (failing + passing) / 2
            if passes(NSColor(hue: hue, saturation: middle, brightness: 1, alpha: alpha)) {
                passing = middle
            } else {
                failing = middle
            }
        }
        return NSColor(hue: hue, saturation: passing, brightness: 1, alpha: alpha)
    }

    // Enough halvings to land inside a step no 8-bit channel can express.
    private static let liftSteps = 12
}

// AppKit twin of `ConnectionTile`: the rail is an `NSTableView` whose cells are `NSTableCellView`s,
// and a hosting view per row would put a SwiftUI tree in every reused cell.
@MainActor
internal final class ConnectionTileView: NSView {
    private let glyph = NSImageView()
    private var glyphWidth: NSLayoutConstraint?
    private var glyphHeight: NSLayoutConstraint?
    private var identityColor: ConnectionColor?
    private var brandColor: NSColor = .secondaryLabelColor
    private var size: CGFloat = 24

    internal var isEmphasized = false {
        didSet {
            guard isEmphasized != oldValue else { return }
            applyTint()
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleProportionallyUpOrDown
        addSubview(glyph)
        let width = glyph.widthAnchor.constraint(equalToConstant: ConnectionTileMetrics.glyphSide(for: size))
        let height = glyph.heightAnchor.constraint(equalToConstant: ConnectionTileMetrics.glyphSide(for: size))
        glyphWidth = width
        glyphHeight = height
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            width,
            height,
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConnectionTileView does not support NSCoder init")
    }

    internal var image: NSImage? {
        glyph.image
    }

    internal var glyphTint: NSColor? {
        glyph.contentTintColor
    }

    internal var fillsWithIdentity: Bool {
        identityColor != nil
    }

    internal func configure(connection: DatabaseConnection, size: CGFloat) {
        self.size = size
        let side = ConnectionTileMetrics.glyphSide(for: size)
        glyphWidth?.constant = side
        glyphHeight?.constant = side
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: ConnectionTileMetrics.glyphPointSize(for: size),
            weight: .medium
        )
        glyph.image = LibraryGlyph.connectionNSImage(
            type: connection.type,
            iconName: connection.iconName,
            accessibilityDescription: connection.type.displayName
        )
        identityColor = connection.identityColor
        brandColor = NSColor(connection.brandColor)
        applyTint()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds,
            xRadius: ConnectionTileMetrics.cornerRadius(for: bounds.width),
            yRadius: ConnectionTileMetrics.cornerRadius(for: bounds.height)
        )
        fillColor.setFill()
        path.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
        needsDisplay = true
    }

    // Resolved on every draw, so a dynamic system colour follows the appearance it is drawn in.
    private var fillColor: NSColor {
        if let identityColor { return NSColor(identityColor.color) }
        return isEmphasized
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.2)
            : .quaternaryLabelColor
    }

    private func applyTint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let identityColor {
                glyph.contentTintColor = NSColor(Color.legibleForeground(on: identityColor.color))
            } else {
                glyph.contentTintColor = isEmphasized
                    ? .alternateSelectedControlTextColor
                    : ConnectionTileMetrics.glyphColor(brand: brandColor)
            }
        }
    }
}
