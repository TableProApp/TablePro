//
//  ConnectionTreeCellView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// One row of the connections tree: a folder, or a connection with its engine glyph and state.
///
/// Three channels, the same split `WorkspaceRailCellView` settled on. The glyph's SHAPE carries the
/// connection's state, because a colour-only difference between failed and disconnected is
/// invisible to anyone who cannot tell red from grey. Its COLOUR is the engine while connected and
/// the state's own colour otherwise. The user's identity colour is a separate dot, so it never has
/// to win an argument with either.
@MainActor
internal final class ConnectionTreeCellView: NSTableCellView {
    internal static let reuseIdentifier = NSUserInterfaceItemIdentifier("ConnectionTreeCell")

    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let identityDot = NSView()

    /// Held as the palette entry rather than a resolved colour: `systemRed` and the rest differ
    /// between light and dark, so resolving at configure time would freeze the dot at the
    /// appearance the row was built in.
    private var identityColor: ConnectionColor?
    private var appliedTint: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConnectionTreeCellView does not support NSCoder init")
    }

    private func buildHierarchy() {
        identifier = Self.reuseIdentifier

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.usesSingleLineMode = true
        label.font = .systemFont(ofSize: NSFont.systemFontSize)

        identityDot.translatesAutoresizingMaskIntoConstraints = false
        identityDot.wantsLayer = true
        identityDot.layer?.cornerRadius = Self.dotSize / 2
        identityDot.isHidden = true

        for child in [glyph, label, identityDot] {
            addSubview(child)
        }
        imageView = glyph
        textField = label

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: ConnectionIconMetrics.row),
            glyph.heightAnchor.constraint(equalToConstant: ConnectionIconMetrics.row),

            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            identityDot.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            identityDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            identityDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            identityDot.widthAnchor.constraint(equalToConstant: Self.dotSize),
            identityDot.heightAnchor.constraint(equalToConstant: Self.dotSize),
        ])
    }

    private static let dotSize: CGFloat = 8

    internal func configureGroup(_ group: ConnectionGroup, isExpanded: Bool) {
        label.stringValue = group.name
        label.textColor = .labelColor
        appliedTint = .secondaryLabelColor
        glyph.image = NSImage(
            systemSymbolName: isExpanded ? "folder" : "folder.fill",
            accessibilityDescription: nil
        )
        glyph.contentTintColor = appliedTint
        identityColor = nil
        identityDot.isHidden = true
        toolTip = group.name
        setAccessibilityLabel(group.name)
    }

    internal func configureConnection(_ connection: DatabaseConnection, status: ConnectionTreeStatus) {
        label.stringValue = connection.name
        label.textColor = .labelColor
        glyph.image = Self.glyph(for: connection, status: status)
        appliedTint = Self.tint(for: connection, status: status)
        glyph.contentTintColor = appliedTint

        identityColor = connection.identityColor
        identityDot.isHidden = identityColor == nil
        applyIdentityColor()

        toolTip = Self.tooltip(for: connection, status: status)
        setAccessibilityLabel(Self.tooltip(for: connection, status: status))
    }

    private func applyIdentityColor() {
        guard let hue = identityColor?.indicatorColor else { return }
        identityDot.layer?.backgroundColor = NSColor(hue).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        /// Both colours were resolved for the appearance the row was built in, and neither follows
        /// a theme change on its own: a layer holds a resolved CGColor, and `contentTintColor` is
        /// resolved at assignment.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            applyIdentityColor()
            glyph.contentTintColor = appliedTint
        }
    }

    /// The shape says the state. Only a connected row shows the engine's own glyph, so an engine
    /// that is not up cannot be mistaken for one that is.
    private static func glyph(for connection: DatabaseConnection, status: ConnectionTreeStatus) -> NSImage? {
        switch status {
        case .connecting:
            return NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        case .failed:
            return NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        case .connected, .notConnected:
            let name = connection.type.iconName
            return NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage(named: name)
        }
    }

    private static func tint(for connection: DatabaseConnection, status: ConnectionTreeStatus) -> NSColor {
        switch status {
        case .connected:
            return NSColor(connection.type.themeColor)
        case .connecting:
            return .secondaryLabelColor
        case .failed:
            return .systemRed
        case .notConnected:
            return .tertiaryLabelColor
        }
    }

    private static func tooltip(for connection: DatabaseConnection, status: ConnectionTreeStatus) -> String {
        let state: String
        switch status {
        case .connected: state = String(localized: "Connected")
        case .connecting: state = String(localized: "Connecting")
        case .failed: state = String(localized: "Not reachable")
        case .notConnected: state = String(localized: "Not connected")
        }
        return "\(connection.name), \(state)"
    }
}
