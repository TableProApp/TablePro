//
//  DataGridRowGutterHeaderView.swift
//  TablePro
//

import AppKit

/// The "#" header, held over the leading edge of the header while it scrolls underneath.
///
/// `DataGridRowGutterView` cannot cover this: `NSScrollView.addFloatingSubview(_:for:)` puts a view
/// over the content clip view, and the header lives in a clip view of its own. A plain subview of
/// the scroll view is what stays put over it, measured to hold its position and hit-test at every
/// scroll offset.
///
/// It draws through `SortableHeaderChrome`, the single owner of header colours and geometry, for the
/// reason that type exists: `NSTableHeaderCell` paints a fixed 28pt band centred in whatever frame
/// it is given, which lands mid-cell once the header grows for a column comment (#2017).
///
/// It swallows its clicks rather than passing them through. The column scrolled under it carries a
/// resize zone and a value-filter funnel, and neither belongs to a strip the pointer is over by
/// accident.
@MainActor
final class DataGridRowGutterHeaderView: NSView {
    weak var coordinator: TableViewCoordinator?

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Sizes and places the cap over the header's leading strip. Hidden when row numbers are off,
    /// and whenever the grid has no header at all, which is how the inspector's grid is configured.
    func synchronizeGeometry(scrollView: NSScrollView) {
        guard let tableView = coordinator?.tableView,
              let header = tableView.headerView,
              header.frame.height > 0 else {
            isHidden = true
            return
        }
        let width = DataGridRowGutterView.width(of: tableView)
        guard width > 0 else {
            isHidden = true
            return
        }
        isHidden = false
        let headerFrame = convertHeaderFrame(header, in: scrollView)
        let target = NSRect(x: headerFrame.minX, y: headerFrame.minY, width: width, height: headerFrame.height)
        guard frame != target else { return }
        frame = target
        needsDisplay = true
    }

    private func convertHeaderFrame(_ header: NSView, in scrollView: NSScrollView) -> NSRect {
        guard let clip = header.superview else { return .zero }
        return scrollView.convert(clip.bounds, from: clip)
    }

    override func draw(_ dirtyRect: NSRect) {
        SortableHeaderChrome.fillBackground(bounds)
        SortableHeaderChrome.drawBottomSeparator(in: bounds)
        SortableHeaderChrome.drawColumnDivider(in: bounds)
        drawTitle()
    }

    /// The same right-aligned "#" the attached column's header cell shows, so the two agree where
    /// they overlap at scroll offset zero.
    private func drawTitle() {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let title = "#" as NSString
        let size = title.size(withAttributes: attributes)
        let inset = DataGridMetrics.cellHorizontalInset
        title.draw(
            at: NSPoint(x: max(inset, bounds.maxX - inset - size.width), y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {}

    override func rightMouseDown(with event: NSEvent) {}

    override func menu(for event: NSEvent) -> NSMenu? { nil }
}
