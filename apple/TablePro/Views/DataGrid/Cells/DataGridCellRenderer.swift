//
//  DataGridCellRenderer.swift
//  TablePro
//

import AppKit
import CoreText
import TableProTextEngine

// The grid draws its cells rather than mounting a view per cell; the only state here is a bounded line cache.
@MainActor
final class DataGridCellRenderer {
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

    // Cleared wholesale rather than evicted one at a time: a miss costs one CTLine.
    private static let lineCacheLimit = 4_096
    // Past this many characters a cell only ever shows an ellipsis.
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
    }

    func drawRowNumber(_ number: Int, in rect: NSRect, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = String(number) as NSString
        let size = text.size(withAttributes: attributes)
        let inset = DataGridMetrics.cellHorizontalInset
        let origin = NSPoint(
            x: max(rect.minX + inset, rect.maxX - inset - size.width),
            y: rect.midY - size.height / 2
        )
        text.draw(at: origin, withAttributes: attributes)
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

    // The mark is part of the key: the same value struck through is a different drawing.
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
            laidOut = laidOut.shownWithoutMarks
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

    // The system's own checkbox cell, so it matches every other checkbox in each appearance and contrast setting.
    private func drawCheckbox(_ mark: DataGridCheckboxMark, in rect: NSRect, controlView: NSView) {
        let frame = DataGridCheckboxMark.frame(in: rect)
        guard !frame.isEmpty else { return }
        checkboxCell.state = mark == .checked ? .on : .off
        checkboxCell.draw(withFrame: frame, in: controlView)
    }
}
