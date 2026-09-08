//
//  TransportRateToolbarItem.swift
//  TablePro
//

import AppKit

/// The throughput readout inside the centred connection group.
///
/// The one place in this toolbar that carries a view, and the reason is that the figure has to hold
/// a constant width. A view-less item would carry it in `title`, and a title re-measures: with the
/// figure written into one and `validateVisibleItems()` called, the group went 219pt, 233pt, 232pt,
/// 251pt across `0 kB/s`, `145 kB/s`, `1.2 MB/s` and `888.8 MB/s`, walking its own midpoint 16pt.
/// A group is laid out around that midpoint, so every one of those steps slides the connection name
/// beside it, once a second.
///
/// A view pinned to a width settles it. Measured across the same four figures, the group frame and
/// the field frame were byte-identical every time: `group.x=396.0 w=248.0`, `field.x=573.0 w=71.0`.
///
/// It publishes no action, so AppKit never validates it and it has no menu-bar command of its own.
/// That is the cost of a readout, and it is why the item is only in the group at all for a
/// connection whose bytes the app carries.
@MainActor
internal final class TransportRateToolbarItem: NSToolbarItem {
    private let field = NSTextField(labelWithString: "")

    internal init() {
        super.init(itemIdentifier: Self.identifier)
        let label = String(localized: "Throughput")
        self.label = label
        paletteLabel = label
        field.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.alignment = .center
        field.lineBreakMode = .byClipping
        field.setAccessibilityLabel(label)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        view = field
        /// After `view`, never before, and this ordering is the whole of it. `NSToolbarItem.h`:
        /// "many of the set/get methods will be implemented by calls forwarded to the view you set,
        /// if it responds to it", and `NSTextField` responds to `setBordered:`. Set first, the flag
        /// is discarded and the readout draws as bare text beside two capsules; set after, AppKit
        /// gives it a real `NSToolbarPlatterView` the same 36pt height and 8pt gap as its
        /// neighbours. Measured: 2 platters and a 14pt-tall field one way, 3 platters and a 36pt
        /// one the other. Writing `field.isBordered = false` anywhere later deletes the capsule
        /// again, just as silently.
        isBordered = true
        overflowEntry.isEnabled = false
        menuFormRepresentation = overflowEntry
        apply(rate: nil)
    }

    internal static let identifier = NSToolbarItem.Identifier("com.TablePro.toolbar.transportRate")

    /// Measured from the widest figure the label can produce rather than typed in, so a change to
    /// the format cannot leave the field a few points too narrow and clip its own text.
    private static let fieldWidth: CGFloat = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let widest = TransportRateLabel.widestCandidates
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return ceil(widest) + 8
    }()

    /// The centred group is the first region AppKit sheds into the overflow menu, so the figure
    /// gets an entry of its own there rather than disappearing with the controls beside it. It is
    /// disabled because there is nothing to click: it reports, it does not do.
    private let overflowEntry = NSMenuItem()

    internal func apply(rate: TransportRate?) {
        let text = TransportRateLabel.text(for: rate)
        guard text != field.stringValue else { return }

        let spoken = TransportRateLabel.accessibilityValue(for: rate)
        field.stringValue = text
        field.setAccessibilityValue(spoken)
        overflowEntry.title = spoken
        toolTip = String(format: String(localized: "%@ through this connection's transport"), spoken)
    }
}
