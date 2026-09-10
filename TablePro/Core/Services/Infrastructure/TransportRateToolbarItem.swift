//
//  TransportRateToolbarItem.swift
//  TablePro
//

import AppKit

/// The throughput readout, beside the centred connection group rather than inside it.
///
/// Bare text with no capsule, which is what Xcode does with the one comparable thing it ships:
/// measured on a running Xcode, its Window Title/Activity readout draws as plain text next to the
/// Back/Forward capsule and wears no platter of its own. A capsule was tried here and it was wrong
/// twice over. `title` on a group subitem is what earns a subitem its own capsule (measured: two
/// titled subitems give two platters, three untitled ones give a single platter spanning all of
/// them, and `controlRepresentation` changes neither), so the centre became three capsules for two
/// controls and one number, and read as scattered.
///
/// Sitting outside the group is what keeps the pair centred. A group is laid out around its own
/// midpoint, so a readout inside it pushed the connection and database capsules off centre by half
/// the readout's width. Measured at 1400pt: with the readout as a separate adjacent item the group
/// sits at x=647.0, midX=772.8, byte-identical to having no readout at all, and the text lands 6.0pt
/// past the group's trailing edge.
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
