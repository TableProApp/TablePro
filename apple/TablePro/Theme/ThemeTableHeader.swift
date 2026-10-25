import AppKit
import TableProTheme

// AppKit's header cell paints an opaque band and colors a title only from the title's own attributes, so the
// header view styles each title before a draw and `ThemeTableHeaderCell` paints the band.
@MainActor
class ThemeTableHeaderView: NSTableHeaderView {
    var themeScope: ThemeScope { .live }

    // On macOS 26 the header sits in the scroll pocket's vibrant banner, which would blend the band lighter (measured).
    override var allowsVibrancy: Bool { false }

    // AppKit bolds the highlighted column's title only in the highlight pass the themed band replaces.
    override func viewWillDraw() {
        super.viewWillDraw()
        guard let tableView else { return }
        let color = themeScope.resolved[.gridHeaderText]
        let highlighted = tableView.highlightedTableColumn
        for column in tableView.tableColumns {
            (column.headerCell as? ThemeTableHeaderCell)?.styleTitle(color: color, bold: column === highlighted)
        }
    }
}

// AppKit copies the last column's cell to draw past the last column, so the cell holds no object references.
@MainActor
final class ThemeTableHeaderCell: NSTableHeaderCell {
    // AppKit's interior band, measured on macOS 27: 16 pt, centered in any header height and for any font.
    static let interiorHeight: CGFloat = 16
    static let lineWidth: CGFloat = 1

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let header = controlView as? NSTableHeaderView
        let resolved = ((header as? ThemeTableHeaderView)?.themeScope ?? .live).resolved
        resolved[.gridHeaderBackground].setFill()
        cellFrame.fill()

        let interior = Self.interiorRect(in: cellFrame)
        resolved[.gridLine].setFill()
        Self.bottomLineRect(in: cellFrame).fill(using: .sourceOver)
        if let tableView = header?.tableView, !Self.isFiller(cellFrame, of: tableView) {
            Self.dividerRect(in: cellFrame, interior: interior).fill(using: .sourceOver)
        }
        drawInterior(withFrame: interior, in: controlView)
    }

    // AppKit's highlight pass draws its own band; the highlighted title is bold instead (`ThemeTableHeaderView`).
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        draw(withFrame: cellFrame, in: controlView)
    }

    func styleTitle(color: NSColor, bold: Bool) {
        let title = attributedStringValue
        guard title.length > 0 else { return }
        let base = font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
        let titleFont = bold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
        if title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == color,
           title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == titleFont {
            return
        }
        let styled = NSMutableAttributedString(attributedString: title)
        styled.addAttributes(
            [.foregroundColor: color, .font: titleFont],
            range: NSRange(location: 0, length: styled.length)
        )
        attributedStringValue = styled
    }

    static func interiorRect(in cellFrame: NSRect) -> NSRect {
        let height = min(interiorHeight, cellFrame.height)
        return NSRect(x: cellFrame.minX, y: cellFrame.midY - height / 2, width: cellFrame.width, height: height)
    }

    static func bottomLineRect(in cellFrame: NSRect) -> NSRect {
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - lineWidth, width: cellFrame.width, height: lineWidth)
    }

    static func dividerRect(in cellFrame: NSRect, interior: NSRect) -> NSRect {
        NSRect(x: cellFrame.maxX - lineWidth, y: interior.minY, width: lineWidth, height: interior.height)
    }

    // The band past the last column has no divider at its end.
    static func isFiller(_ cellFrame: NSRect, of tableView: NSTableView) -> Bool {
        guard tableView.numberOfColumns > 0 else { return true }
        return cellFrame.minX >= tableView.rect(ofColumn: tableView.numberOfColumns - 1).maxX
    }
}
