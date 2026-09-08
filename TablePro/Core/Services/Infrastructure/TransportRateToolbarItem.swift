//
//  TransportRateToolbarItem.swift
//  TablePro
//

import AppKit

/// The throughput readout inside the centred connection group.
///
/// The one place in this toolbar that carries a view, and the reason is measured. AppKit sizes a
/// view-less item's `title` **once, when the item is inserted**: setting a longer title afterwards
/// leaves the item at its original width and clips the text, and neither `validateVisibleItems()`
/// nor a window resize re-measures it. Only a `displayMode` round trip or removing and re-inserting
/// the item does, and both rebuild the toolbar visibly. So a figure that changes once a second
/// cannot live in a title.
///
/// The other half of the measurement is why the view is a fixed width rather than sized to its text.
/// The centred group is laid out around its midpoint, so a group that grows by 14pt moves its
/// leading edge 7pt one way and the database item 7pt the other. Measured at 1200pt: the same group
/// sat at x=488.5 reading `↓0 kB/s` and x=481.5 reading `↓145 kB/s`. With the width pinned, changing
/// the text moves nothing at all: group and field frames were identical across `↓0 kB/s`,
/// `↓145 kB/s`, `↑1.2 MB/s` and `↓88 MB/s`.
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
