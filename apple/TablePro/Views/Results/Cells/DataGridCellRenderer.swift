//
//  DataGridCellRenderer.swift
//  TablePro
//

import AppKit
import CoreText
import TableProTextEngine

/// Draws one data cell into a rect.
///
/// The grid draws its cells rather than mounting a view for each, so the drawing has to live apart
/// from any view. Everything here is a function of the appearance it is handed; the only state is a
/// bounded cache of laid-out lines, because building a `CTLine` is the expensive part of a cell and
/// scrolling redraws the same values over and over.
@MainActor
final class DataGridCellRenderer {
    /// A laid-out line depends on nothing but the text and the two attributes it carries, so this is
    /// the whole identity of a cached line.
    private struct LineKey: Hashable {
        let text: String
        let font: NSFont
        let color: NSColor
        let mark: DataGridCellTextMark?
        let specialCharacterColor: NSColor?
    }

    private struct LaidOutLine {
        let line: CTLine
        let specialCharacters: SpecialCharacterLine?
    }

    /// A viewport holds a few hundred cells and a scroll reuses them, so this only has to outlive a
    /// few screens. Cleared wholesale rather than evicted one at a time: the cost of a miss is one
    /// `CTLine`, and tracking recency would cost more than it saves.
    private static let lineCacheLimit = 4_096
    /// Past this many characters a cell can only ever show an ellipsis, and laying out the rest is
    /// wasted on a value the reader opens the inspector to read anyway.
    private static let maximumLaidOutCharacters = 300

    private var lineCache: [LineKey: LaidOutLine] = [:]

    private let checkboxCell: NSButtonCell = {
        let cell = NSButtonCell()
        cell.setButtonType(.switch)
        cell.title = ""
        cell.imagePosition = .imageOnly
        cell.controlSize = .small
        return cell
    }()

    func invalidateCachedLines() {
        lineCache.removeAll(keepingCapacity: true)
    }

    func draw(_ appearance: DataGridCellAppearance, in rect: NSRect, controlView: NSView? = nil) {
        guard rect.width > 0, rect.height > 0 else { return }

        if let tint = appearance.backgroundTint {
            tint.setFill()
            rect.fill()
        }

        let accessoryRect = appearance.accessory.frame(in: rect)

        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        drawText(appearance, in: rect)
        drawAccessory(appearance.accessoryRole, color: appearance.accessoryColor, in: accessoryRect)
        if let mark = appearance.checkboxMark, let controlView {
            drawCheckbox(mark, in: rect, controlView: controlView)
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        if appearance.drawsFocusBorder || appearance.drawsFocusRing {
            drawCursor(in: rect, color: appearance.focusColor)
        }
    }

    private func drawText(_ appearance: DataGridCellAppearance, in rect: NSRect) {
        guard !appearance.text.isEmpty else { return }
        let availableWidth = appearance.accessory.availableTextWidth(in: rect)
        guard availableWidth > 0, let context = NSGraphicsContext.current?.cgContext else { return }

        let laidOut = line(for: appearance.text, appearance: appearance)
        let fullLine = laidOut.line
        let typographicWidth = CTLineGetTypographicBounds(fullLine, nil, nil, nil)
        let ellipsis = line(for: "\u{2026}", appearance: appearance).line
        let ellipsisWidth = CTLineGetTypographicBounds(ellipsis, nil, nil, nil)
        guard Double(availableWidth) >= ellipsisWidth else { return }

        let fits = typographicWidth <= Double(availableWidth)
        let truncated = fits ? nil : CTLineCreateTruncatedLine(fullLine, Double(availableWidth), .end, ellipsis)
        let lineToDraw = fits ? fullLine : (truncated ?? ellipsis)

        let font = appearance.font
        let baselineOffset = (rect.height - font.ascender + font.descender - font.leading) / 2 + font.ascender

        let textX = rect.minX + DataGridMetrics.cellHorizontalInset
        let baseline = rect.minY + baselineOffset
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: textX, y: baseline)
        CTLineDraw(lineToDraw, context)
        if let specialCharacters = laidOut.specialCharacters, fits || truncated != nil {
            SpecialCharacterLine.draw(
                specialCharacters.marks(drawnIn: lineToDraw),
                fromX: textX,
                top: baseline - font.ascender,
                height: font.ascender - font.descender,
                in: context
            )
        }
        context.restoreGState()
    }

    /// Built with the mark's own attribute so `CTLineDraw` draws the line from the font's metrics,
    /// and so `CTLineCreateTruncatedLine` carries it onto a truncated line and its ellipsis. The
    /// mark is part of the key because two cells holding the same value in the same font and colour
    /// are two different drawings once one of them is struck through.
    private func line(for text: String, appearance: DataGridCellAppearance) -> LaidOutLine {
        let font = appearance.font
        let key = LineKey(
            text: text,
            font: font,
            color: appearance.textColor,
            mark: appearance.textMark,
            specialCharacterColor: appearance.specialCharacterColor
        )
        if let cached = lineCache[key] { return cached }

        let source = text as NSString
        var laidOut = source.length > Self.maximumLaidOutCharacters
            ? source.substring(to: Self.maximumLaidOutCharacters) + "\u{2026}"
            : text
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: appearance.textColor]
        appearance.textMark?.attributes.forEach { attributes[$0.key] = $0.value }

        let created: LaidOutLine
        if let markColor = appearance.specialCharacterColor {
            let marked = SpecialCharacterLine(
                NSAttributedString(string: laidOut, attributes: attributes),
                style: SpecialCharacterStyle(color: markColor, marksLineBreaks: true)
            )
            created = LaidOutLine(line: marked.line, specialCharacters: marked.marks.isEmpty ? nil : marked)
        } else {
            // The formatter keeps a lone CR for the marks; unmarked it reads as the space it always did.
            laidOut = laidOut.replacingOccurrences(of: "\r", with: " ", options: .literal)
            let attributed = NSAttributedString(string: laidOut, attributes: attributes)
            created = LaidOutLine(line: CTLineCreateWithAttributedString(attributed as CFAttributedString), specialCharacters: nil)
        }

        if lineCache.count >= Self.lineCacheLimit {
            lineCache.removeAll(keepingCapacity: true)
        }
        lineCache[key] = created
        return created
    }

    private func drawAccessory(_ role: DataGridCellAccessoryGlyph.Role?, color: NSColor?, in rect: NSRect) {
        guard !rect.isEmpty, let role, let color else { return }
        guard let glyph = DataGridCellAccessoryGlyph.image(for: role, color: color),
              let context = NSGraphicsContext.current?.cgContext else { return }

        let drawRect = DataGridCellAccessoryGlyph.centeredRect(pointSize: glyph.pointSize, in: rect)
        context.saveGState()
        context.translateBy(x: drawRect.minX, y: drawRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(glyph.image, in: CGRect(origin: .zero, size: drawRect.size))
        context.restoreGState()
    }

    /// Drawn by the system's own checkbox cell, so it matches every other checkbox in the window in
    /// each appearance and contrast setting rather than approximating one with a symbol.
    private func drawCheckbox(_ mark: DataGridCheckboxMark, in rect: NSRect, controlView: NSView) {
        let frame = DataGridCheckboxMark.frame(in: rect)
        guard !frame.isEmpty else { return }
        checkboxCell.state = mark == .checked ? .on : .off
        checkboxCell.draw(withFrame: frame, in: controlView)
    }

    /// A mounted cell got its cursor from AppKit's exterior focus ring; a drawn cell has no view to
    /// hang one on, so it is drawn to the same shape.
    private func drawCursor(in rect: NSRect, color: NSColor) {
        let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        color.setStroke()
        path.stroke()
    }
}
