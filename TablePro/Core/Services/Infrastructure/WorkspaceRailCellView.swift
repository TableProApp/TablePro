//
//  WorkspaceRailCellView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// One workspace: a glyph above the container it browses, with the connection's own colour as a
/// dot on the glyph's corner.
///
/// Three channels share this cell and each owns a different property of the same glyph. Its SHAPE
/// is the connection's state, because a colour-only difference between failed and disconnected is
/// invisible to anyone who cannot tell red from grey. Its COLOUR is the engine when connected and
/// the state's own colour when not. The user's identity colour is a separate dot, so it never has
/// to win an argument with either.
///
/// The dot is what Finder puts on a tag row and what this app already puts beside a connection in
/// the welcome list and the connection switcher, measured at 12.5pt and 8pt respectively. It
/// replaced a full-width filled band behind the label, which was the loudest element in the window,
/// stacked on top of the selection fill, and read as destructive rather than as a label (#2398).
///
/// Unlike the glyph tint, the dot stays lit on the selected row: the HIG's sidebar guidance is that
/// a fixed colour set to clarify an icon is not overridden by the system, and the selected row is
/// the one whose identity the user most needs to confirm. A rim in the selection's own label colour
/// is what keeps it legible against the accent fill, which seven of the eight palette colours
/// otherwise fail 3:1 against.
///
/// The label keeps its single line and its middle truncation. Wrapping to two was tried and is
/// worse: underscore is Unicode class AL and offers no break, so `tablepro_license` breaks at the
/// width limit into `tablepro_licens` and an orphaned `e`. The HIG's reason for middle truncation
/// in a narrow column stands, and the full name is in the tooltip and the accessibility label.
@MainActor
internal final class WorkspaceRailCellView: NSTableCellView {
    internal static let reuseIdentifier = NSUserInterfaceItemIdentifier("WorkspaceRailCell")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let identityDot = NSView()
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?
    private var dotWidthConstraint: NSLayoutConstraint?
    private var dotHeightConstraint: NSLayoutConstraint?
    private var appliedTint: NSColor?
    /// Held as the palette entry rather than a resolved colour, because `systemRed` and the rest
    /// differ between light and dark: resolving at configure time would freeze the dot at the
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

        identityDot.translatesAutoresizingMaskIntoConstraints = false
        identityDot.wantsLayer = true
        identityDot.layer?.borderWidth = Self.identityDotRimWidth

        addSubview(icon)
        addSubview(label)
        addSubview(identityDot)
        imageView = icon
        textField = label

        let width = icon.widthAnchor.constraint(equalToConstant: 24)
        let height = icon.heightAnchor.constraint(equalToConstant: 24)
        iconWidthConstraint = width
        iconHeightConstraint = height

        let dotWidth = identityDot.widthAnchor.constraint(equalToConstant: Self.identityDotSize(forIcon: 24))
        let dotHeight = identityDot.heightAnchor.constraint(equalToConstant: Self.identityDotSize(forIcon: 24))
        dotWidthConstraint = dotWidth
        dotHeightConstraint = dotHeight

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            width,
            height,

            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),

            dotWidth,
            dotHeight,
            identityDot.centerXAnchor.constraint(equalTo: icon.trailingAnchor),
            identityDot.centerYAnchor.constraint(equalTo: icon.bottomAnchor),
        ])
    }

    /// Sized against the glyph rather than fixed, so it keeps the same proportion at every
    /// System Settings sidebar icon size. At the medium rail this is 9pt, between the 8pt dot the
    /// welcome list already draws and the 12.5pt one measured on a Finder tag.
    internal static func identityDotSize(forIcon iconSize: CGFloat) -> CGFloat {
        (iconSize * 0.375).rounded()
    }

    private static let identityDotRimWidth: CGFloat = 1.5

    internal func configure(entry: WorkspaceRailEntry, layout: WorkspaceRailMetrics.Layout) {
        iconWidthConstraint?.constant = layout.iconSize
        iconHeightConstraint?.constant = layout.iconSize

        let dotSize = Self.identityDotSize(forIcon: layout.iconSize)
        dotWidthConstraint?.constant = dotSize
        dotHeightConstraint?.constant = dotSize
        identityDot.layer?.cornerRadius = dotSize / 2

        label.font = .systemFont(ofSize: layout.fontSize)
        label.stringValue = entry.container.isEmpty ? entry.connection.name : entry.container

        appliedTint = Self.glyphTint(for: entry)
        identityColor = entry.connection.identityColor
        icon.image = Self.glyph(for: entry)
        identityDot.isHidden = identityColor == nil
        applyTint()

        toolTip = Self.tooltipText(for: entry)
        setAccessibilityLabel(Self.voiceOverLabel(for: entry))
    }

    /// On the selected row `NSTableCellView` already tints the image view for contrast, so the
    /// glyph steps aside rather than competing with the selection fill, which it loses against at
    /// every accent colour. The identity dot does not step aside with it: it is the one thing on
    /// the row the selection cannot restate, and its rim is what carries it over the accent fill.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTint() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    private func applyTint() {
        let isEmphasized = backgroundStyle == .emphasized
        effectiveAppearance.performAsCurrentDrawingAppearance {
            icon.contentTintColor = isEmphasized ? nil : appliedTint

            guard let hue = identityColor?.indicatorColor else { return }
            identityDot.layer?.backgroundColor = NSColor(hue).cgColor
            /// The rim punches the dot out of whatever sits behind it. On the selected row that is
            /// the accent fill, which red, blue, purple, pink and grey all fail 3:1 against, so the
            /// rim takes the colour AppKit itself uses for content on a selection.
            identityDot.layer?.borderColor = isEmphasized
                ? NSColor.alternateSelectedControlTextColor.cgColor
                : NSColor.windowBackgroundColor.cgColor
        }
    }

    /// The glyph's colour follows what its shape is saying. Tinting every state with the engine's
    /// brand colour, which is what this used to do, painted a failed PostgreSQL connection's
    /// warning triangle PostgreSQL blue: the one glyph that exists to raise an alarm wore the
    /// calmest colour on the row. Identity never reaches here, so a connection the user named Red
    /// and a connection that failed stay distinguishable.
    internal static func glyphTint(for entry: WorkspaceRailEntry) -> NSColor {
        switch entry.status {
        case .error:
            return .systemRed
        case .disconnected:
            return .secondaryLabelColor
        case .connecting, .connected:
            return NSColor(entry.connection.brandColor)
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
