//
//  WorkspaceRailCellView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// One workspace: the engine's glyph above the container it browses, over the connection's own
/// colour.
///
/// The glyph carries the engine and the band behind the label carries the user's pick. This cell
/// used to put both on the glyph, on the reasoning that "the colour is the icon", which is how
/// Finder carries a tag. That holds for a Finder icon, which is a neutral document or folder shape
/// with no colour of its own to lose. An engine glyph is not neutral: it is a brand mark that is
/// already a colour meaning something else, so the two readings competed for one shape and the
/// engine's lost. Picking a colour only shifted the glyph's hue, which is the complaint #2398
/// reports. State stays on the glyph's shape, not on either colour, so it still survives colour
/// blindness and Increase Contrast, and the colour's name joins the tooltip and the accessibility
/// label so it is never the only channel. The label truncates in the middle, which the HIG
/// recommends for narrow columns because it keeps both ends of the name recognisable, and
/// the full name, host and container stay in the tooltip and the accessibility label.
@MainActor
internal final class WorkspaceRailCellView: NSTableCellView {
    internal static let reuseIdentifier = NSUserInterfaceItemIdentifier("WorkspaceRailCell")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let identityBand = NSView()
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?
    private var appliedTint: NSColor?
    /// Held as the palette entry rather than a resolved colour, because `systemRed` and the rest
    /// differ between light and dark: resolving at configure time would freeze the band at the
    /// appearance the row was built in and `viewDidChangeEffectiveAppearance` would repaint it with
    /// the stale value.
    private var identityColor: ConnectionColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WorkspaceRailCellView does not support NSCoder init")
    }

    private func buildHierarchy() {
        identifier = Self.reuseIdentifier

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.allowsExpansionToolTips = true
        label.cell?.truncatesLastVisibleLine = true

        identityBand.translatesAutoresizingMaskIntoConstraints = false
        identityBand.wantsLayer = true
        identityBand.layer?.cornerRadius = Self.identityBandCornerRadius
        identityBand.layer?.cornerCurve = .continuous

        addSubview(icon)
        addSubview(identityBand)
        addSubview(label)
        imageView = icon
        textField = label

        let width = icon.widthAnchor.constraint(equalToConstant: 24)
        let height = icon.heightAnchor.constraint(equalToConstant: 24)
        iconWidthConstraint = width
        iconHeightConstraint = height

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            width,
            height,

            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),

            identityBand.leadingAnchor.constraint(equalTo: leadingAnchor),
            identityBand.trailingAnchor.constraint(equalTo: trailingAnchor),
            identityBand.topAnchor.constraint(equalTo: label.topAnchor, constant: -Self.identityBandInset),
            identityBand.bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: Self.identityBandInset),
        ])
    }

    private static let identityBandCornerRadius: CGFloat = 4
    private static let identityBandInset: CGFloat = 2

    internal func configure(entry: WorkspaceRailEntry, layout: WorkspaceRailMetrics.Layout) {
        iconWidthConstraint?.constant = layout.iconSize
        iconHeightConstraint?.constant = layout.iconSize

        label.font = .systemFont(ofSize: layout.fontSize)
        label.stringValue = entry.container.isEmpty ? entry.connection.name : entry.container

        appliedTint = NSColor(entry.connection.brandColor)
        identityColor = entry.connection.identityColor
        icon.image = Self.glyph(for: entry)
        applyTint()

        toolTip = Self.tooltipText(for: entry)
        setAccessibilityLabel(Self.voiceOverLabel(for: entry))
    }

    /// On the selected row `NSTableCellView` already tints the image view for contrast, so
    /// the connection colour steps aside rather than competing with the selection fill, which
    /// it loses against at every accent colour. The identity band steps aside with it, for the
    /// same reason: a fill of its own under the selection fill reads as two overlapping bands.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTint() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    private func applyTint() {
        guard backgroundStyle != .emphasized else {
            icon.contentTintColor = nil
            identityBand.layer?.backgroundColor = nil
            label.textColor = nil
            return
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            icon.contentTintColor = appliedTint
            guard let fill = identityColor?.labelledFill else {
                identityBand.layer?.backgroundColor = nil
                label.textColor = nil
                return
            }
            identityBand.layer?.backgroundColor = NSColor(fill).cgColor
            label.textColor = NSColor(Color.legibleForeground(on: fill))
        }
    }

    /// Shape carries the state. A colour-only difference between a failed connection and a
    /// disconnected one is invisible to anyone who cannot tell red from grey.
    private static func glyph(for entry: WorkspaceRailEntry) -> NSImage? {
        switch entry.status {
        case .error:
            return symbol("exclamationmark.triangle.fill", label: String(localized: "connection failed"))
        case .disconnected:
            return symbol("bolt.horizontal.circle", label: String(localized: "disconnected"))
        case .connecting, .connected:
            return engineGlyph(for: entry.connection)
        }
    }

    private static func engineGlyph(for connection: DatabaseConnection) -> NSImage? {
        let name = connection.type.iconName
        if let image = symbol(name, label: connection.type.rawValue) {
            return image
        }
        let image = NSImage(named: name)
        image?.isTemplate = true
        return image
    }

    private static func symbol(_ name: String, label: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: label) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    internal static func tooltipText(for entry: WorkspaceRailEntry) -> String {
        let connection = entry.connection
        var parts = [connection.name]
        if !connection.host.isEmpty {
            parts.append(connection.host)
        }
        if !entry.container.isEmpty {
            parts.append(entry.container)
        }
        if let identity = connection.identityColor {
            parts.append(String(format: String(localized: "Color: %@"), identity.displayName))
        }
        return parts.joined(separator: " · ")
    }

    internal static func voiceOverLabel(for entry: WorkspaceRailEntry) -> String {
        var parts = [entry.connection.name]
        if !entry.container.isEmpty {
            parts.append(String(format: containerFormat(for: entry.containerTarget), entry.container))
        }
        parts.append(statusDescription(for: entry.status))
        if let identity = entry.connection.identityColor {
            parts.append(String(format: String(localized: "color %@"), identity.displayName))
        }
        return parts.joined(separator: ", ")
    }

    private static func containerFormat(for target: ContainerSwitchTarget?) -> String {
        switch target {
        case .schema:
            return String(localized: "schema %@")
        case .database, nil:
            return String(localized: "database %@")
        }
    }

    private static func statusDescription(for status: ConnectionStatus) -> String {
        switch status {
        case .connected:
            return String(localized: "connected")
        case .connecting:
            return String(localized: "connecting")
        case .disconnected:
            return String(localized: "disconnected")
        case .error:
            return String(localized: "connection failed")
        }
    }
}
