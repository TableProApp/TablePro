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
                glyph.contentTintColor = isEmphasized ? .alternateSelectedControlTextColor : brandColor
            }
        }
    }
}
