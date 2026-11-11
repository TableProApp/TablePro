//
//  EditorTabStripLayout.swift
//  TablePro
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// The geometry and visibility rules of the editor tab strip, kept apart from the view so they
/// can be tested. Every number here was measured off `NSTabBar`, the private control the system's
/// own window tab bar is built from, rather than designed: a runtime probe of its view tree on
/// macOS 27 gives a 36pt titlebar accessory holding a 28pt bar, whose track is inset 8pt, then 4pt
/// of gap, then a 28pt new-tab button, then 8pt to the trailing edge.
internal enum EditorTabStripLayout {
    internal static let unseenGlyphSize: CGFloat = 10

    /// The titlebar accessory's own height. The track is pinned to its top edge, flush against the
    /// toolbar, and what remains below is the clearance the system leaves before the content.
    internal static let bandHeight: CGFloat = 36
    internal static let trackHeight: CGFloat = 28
    internal static let tabHeight: CGFloat = 24
    internal static let trackPadding: CGFloat = 2
    internal static let stripInset: CGFloat = 8
    internal static let trackSpacing: CGFloat = 4
    internal static let newTabButtonSize: CGFloat = 28
    internal static let minimumTabWidth: CGFloat = 120
    internal static let separatorHeight: CGFloat = 16
    internal static let accessoryWidth: CGFloat = 16
    internal static let accessoryInset: CGFloat = 5
    internal static let fontSize: CGFloat = 11
    internal static let pinGlyphSize: CGFloat = 9
    internal static let objectGlyphSize: CGFloat = 10
    internal static let pinSpacing: CGFloat = 3

    /// One device pixel on the 2x displays this chrome is drawn for, which is what the system uses
    /// for both the track's edge and the rule between two tabs.
    internal static let hairline: CGFloat = 0.5

    internal static var bandBottomClearance: CGFloat { bandHeight - trackHeight }

    /// The gap between two wrapped rows, and the pitch that follows from it.
    internal static let rowSpacing: CGFloat = 2
    internal static var rowStride: CGFloat { tabHeight + rowSpacing }

    /// A wrapped strip grows the track and the band with it, so the content below is laid out
    /// around the taller band rather than behind it. One row resolves to the measured numbers.
    internal static func trackHeight(forRowCount rows: Int) -> CGFloat {
        trackHeight + CGFloat(max(rows, 1) - 1) * rowStride
    }

    internal static func bandHeight(forRowCount rows: Int) -> CGFloat {
        bandHeight + CGFloat(max(rows, 1) - 1) * rowStride
    }

    /// How close to the viewport's edge the pointer has to come before a reorder starts scrolling
    /// the track under it. One tab's minimum width would swallow the whole viewport on a narrow
    /// window, so this is a fixed band, the same shape `NSView.autoscroll(with:)` applies.
    internal static let autoscrollMargin: CGFloat = 24
    internal static let autoscrollStep: CGFloat = 12

    /// How far the pointer has to leave the strip before a reorder becomes a tear-off. Measured
    /// against the band rather than the tab, so a drag that stays in the chrome is still a reorder.
    internal static let tearOffThreshold: CGFloat = 44

    /// Fully rounded, because that is what the system's own tab bar is: the runtime
    /// probe reports `cornerRadius = 12` on each 24pt `NSGlassEffectView` tab, which is exactly
    /// half its height, and a corner fit of the 28pt track lands at 12 to 14pt. An in-content
    /// `NSSegmentedControl` is the shallower shape, `(height - 4) / 4`, but that is a different
    /// control in a different place; this strip is the titlebar tab bar.
    internal static var trackShape: Capsule { Capsule(style: .continuous) }
    internal static var tabShape: Capsule { Capsule(style: .continuous) }

    /// A capsule is only the system's shape while the track is one row tall. Its radius is half
    /// the height, so a wrapped track would round away most of the first and last rows rather
    /// than its ends, and the close button drawn in that corner would disappear under the curve
    /// while the pointer still hit-tests the full rectangle. Past one row the corner holds at the
    /// radius a single row would have had.
    internal static func trackShape(forRowCount rows: Int) -> AnyShape {
        guard rows > 1 else { return AnyShape(trackShape) }
        return AnyShape(RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous))
    }

    /// Tabs share the track equally, and stop shrinking at a width that still fits a name so a
    /// long list scrolls instead of collapsing into slivers. The system staggers widths slightly
    /// by an undocumented rule; an equal share is within a couple of points of it.
    internal static func tabWidth(forTrack width: CGFloat, count: Int) -> CGFloat {
        let usable = width - trackPadding * 2
        let divisor = CGFloat(max(count, 1))
        return max(usable / divisor, minimumTabWidth)
    }

    /// The widest a located tab grows to show its whole title. Past it the title takes its short form.
    internal static let maximumLocatedTabWidth: CGFloat = 320

    /// The widths of a scrolling run in which some tabs ask for a width of their own, in run order.
    ///
    /// A located title, `orders@shop_demo (Shop Demo)`, is longer than an equal share of a strip with a
    /// few tabs open, and the share cut it to `orders@shop_dem…` while the tabs beside it, `Query 1`,
    /// held room they did not need. So a tab asking for more than the share takes it, up to the
    /// maximum, from the tabs that ask for none, which give it up only down to the minimum a name fits
    /// in. A tab asking for less than the share never drops below what it asked for. When the others
    /// are at that minimum, the asking tabs share what is left evenly, never below the share itself.
    /// Nothing asks: every tab gets the share, exactly as before.
    internal static func tabWidths(forTrack width: CGFloat, preferred: [CGFloat?]) -> [CGFloat] {
        let count = preferred.count
        guard count > 0 else { return [] }
        let share = tabWidth(forTrack: width, count: count)
        let asked = preferred.map { $0.map { min(max($0, minimumTabWidth), maximumLocatedTabWidth) } }
        let growing = asked.indices.filter { (asked[$0] ?? 0) > share }
        guard !growing.isEmpty else { return Array(repeating: share, count: count) }

        let usable = max(width - trackPadding * 2, 0)
        let others = asked.indices.filter { !growing.contains($0) }
        let floors = others.map { asked[$0] ?? minimumTabWidth }
        let room = usable - floors.reduce(0, +)
        let level = cappingLevel(growing.map { asked[$0] ?? share }, total: room)

        var widths = Array(repeating: share, count: count)
        for index in growing {
            let wanted = asked[index] ?? share
            widths[index] = min(wanted, max(level ?? wanted, share))
        }
        let rest = usable - growing.reduce(0) { $0 + widths[$1] }
        let raised = raisingLevel(floors, total: rest)
        for (index, floor) in zip(others, floors) {
            widths[index] = max(floor, raised)
        }
        return widths
    }

    /// The level `L` at which every value capped at `L` adds up to `total`, or nil when the values fit
    /// as they are.
    private static func cappingLevel(_ values: [CGFloat], total: CGFloat) -> CGFloat? {
        guard values.reduce(0, +) > total else { return nil }
        var remaining = total
        let sorted = values.sorted()
        for (position, value) in sorted.enumerated() {
            let even = remaining / CGFloat(sorted.count - position)
            if value >= even { return even }
            remaining -= value
        }
        return nil
    }

    /// The level `L` at which every value raised to `L` adds up to `total`, or zero when the values
    /// already take more than it.
    private static func raisingLevel(_ values: [CGFloat], total: CGFloat) -> CGFloat {
        var remaining = total
        let sorted = values.sorted(by: >)
        for (position, value) in sorted.enumerated() {
            let even = remaining / CGFloat(sorted.count - position)
            if value <= even { return even }
            remaining -= value
        }
        return 0
    }

    /// The width a located tab asks for, keyed by tab. Only a located title asks: every other title is
    /// short enough for the share, which is what it always had.
    @MainActor
    internal static func preferredWidths(
        tabs: [QueryTab],
        labels: [UUID: EditorTabLabelResolver.Label]
    ) -> [UUID: CGFloat] {
        tabs.reduce(into: [:]) { widths, tab in
            guard let label = labels[tab.id], label.shortForm != nil else { return }
            widths[tab.id] = min(
                naturalWidth(of: label, isPinned: tab.isPinned, isPreview: tab.isPreview),
                maximumLocatedTabWidth
            )
        }
    }

    /// What a tab needs to draw `label` whole: the close button's slot and the trailing slot that balances
    /// it, their insets, the glyphs and the title in the strip's face. Rounded up, with a point to spare,
    /// because a text measured to the exact width can still truncate once laid out.
    internal static func naturalWidth(of label: EditorTabLabelResolver.Label, isPinned: Bool, isPreview: Bool) -> CGFloat {
        var glyphs: [CGFloat] = []
        if isPinned {
            glyphs.append(symbolWidth("pin.fill", pointSize: pinGlyphSize))
        }
        if let icon = label.icon {
            glyphs.append(symbolWidth(icon.symbolName, pointSize: objectGlyphSize))
        }
        let parts = glyphs + [textWidth(label.text, isPreview: isPreview)]
        let spacing = pinSpacing * CGFloat(parts.count - 1)
        return ceil(accessoryInset * 2 + accessoryWidth * 2 + parts.reduce(0, +) + spacing) + 1
    }

    /// The title's width in the face the strip draws it in, italic for a preview.
    internal static func textWidth(_ text: String, isPreview: Bool) -> CGFloat {
        let regular = NSFont.systemFont(ofSize: fontSize)
        let font = isPreview ? NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask) : regular
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func symbolWidth(_ name: String, pointSize: CGFloat) -> CGFloat {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        return ceil(image?.size.width ?? pointSize)
    }

    /// How far a tab fades while it is the one being dragged. Enough to read as lifted out of the
    /// strip, not so far that its title stops being legible on the way past its neighbours.
    internal static let draggingOpacity: CGFloat = 0.45

    /// A tab being torn off fades further than one being reordered, so the gesture says which of
    /// the two it is before the pointer comes up.
    internal static let tearingOffOpacity: CGFloat = 0.2

    /// How far the pointer travels before a press on a tab becomes a reorder rather than a click.
    /// The same distance AppKit uses to tell a click from a drag, so a hand that shifts a point or
    /// two while clicking still selects the tab.
    internal static let reorderThreshold: CGFloat = 4

    /// A separator is drawn at the leading edge of a tab only when both it and its leading
    /// neighbour are plain and untouched. A line against the raised capsule reads as a seam in
    /// it, and one against a hovered tab fights that tab's fill. Two tabs therefore never show
    /// one, because one of them is always selected.
    internal static func showsSeparator(
        before index: Int,
        tabIds: [UUID],
        selectedId: UUID?,
        hoveredId: UUID?,
        isReordering: Bool = false
    ) -> Bool {
        guard !isReordering, index > 0 else { return false }
        guard tabIds.indices.contains(index), tabIds.indices.contains(index - 1) else { return false }
        let leading = tabIds[index - 1]
        let trailing = tabIds[index]
        guard leading != selectedId, trailing != selectedId else { return false }
        return leading != hoveredId && trailing != hoveredId
    }
}
