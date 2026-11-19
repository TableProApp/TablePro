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
    // Keyed on the text a cell can show, so a long value hashes in constant time.
    private struct LineKey: Hashable {
        let shownText: String
        let isClipped: Bool
        let font: NSFont
        let color: NSColor
        let mark: DataGridCellTextMark?
        let specialCharacterColor: NSColor?
    }

    private final class LaidOutLine {
        let line: CTLine
        let width: Double
        let specialCharacters: SpecialCharacterLine?
        // A value keeps its column's width from one draw to the next.
        private var truncation: (width: Double, line: CTLine?)?

        init(line: CTLine, specialCharacters: SpecialCharacterLine?) {
            self.line = line
            self.specialCharacters = specialCharacters
            width = CTLineGetTypographicBounds(line, nil, nil, nil)
        }

        // Nil when not even a truncated line fits, which leaves the ellipsis alone.
        func fitted(to availableWidth: Double, ellipsis: CTLine) -> CTLine? {
            guard width > availableWidth else { return line }
            if let truncation, truncation.width == availableWidth { return truncation.line }
            let truncated = CTLineCreateTruncatedLine(line, availableWidth, .end, ellipsis)
            truncation = (availableWidth, truncated)
            return truncated
        }
    }

    private struct RowNumberKey: Hashable {
        let number: Int
        let font: NSFont
        let color: NSColor
    }

    // Cleared wholesale rather than evicted one at a time: a miss costs one CTLine.
    private static let lineCacheLimit = 4_096
    // Past this many characters a cell only ever shows an ellipsis.
    private static let maximumLaidOutCharacters = 300

    private var lineCache: [LineKey: LaidOutLine] = [:]
    private var rowNumberLines: [RowNumberKey: CTLine] = [:]
    private var rowNumberMetrics: (font: NSFont, lineHeight: CGFloat, baselineOffset: CGFloat)?

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
        rowNumberLines.removeAll(keepingCapacity: true)
    }

    func draw(_ appearance: DataGridCellAppearance, in rect: NSRect, controlView: NSView? = nil) {
        guard rect.width > 0, rect.height > 0, let context = NSGraphicsContext.current?.cgContext else { return }

        if let tint = appearance.backgroundTint {
            tint.setFill()
            rect.fill()
        }

        let accessoryRect = appearance.accessory.frame(in: rect)

        context.saveGState()
        context.clip(to: rect)
        drawText(appearance, in: rect, context: context)
        drawAccessory(appearance.accessoryRole, color: appearance.accessoryColor, in: accessoryRect)
        if let mark = appearance.checkboxMark, let controlView {
            drawCheckbox(mark, in: rect, controlView: controlView)
        }
        context.restoreGState()
    }

    func drawRowNumber(_ number: Int, in rect: NSRect, font: NSFont, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let line = rowNumberLine(number, font: font, color: color)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let inset = DataGridMetrics.cellHorizontalInset
        let metrics = rowNumberLineMetrics(font)
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(
            x: max(rect.minX + inset, rect.maxX - inset - width),
            y: rect.midY - metrics.lineHeight / 2 + metrics.baselineOffset
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // String drawing's own line box, which the font's ascent and descent do not add up to.
    private func rowNumberLineMetrics(_ font: NSFont) -> (lineHeight: CGFloat, baselineOffset: CGFloat) {
        if let metrics = rowNumberMetrics, metrics.font == font { return (metrics.lineHeight, metrics.baselineOffset) }
        let lineHeight = ("0" as NSString).size(withAttributes: [.font: font]).height
        let baselineOffset = NSLayoutManager().defaultBaselineOffset(for: font)
        rowNumberMetrics = (font, lineHeight, baselineOffset)
        return (lineHeight, baselineOffset)
    }

    private func rowNumberLine(_ number: Int, font: NSFont, color: NSColor) -> CTLine {
        let key = RowNumberKey(number: number, font: font, color: color)
        if let cached = rowNumberLines[key] { return cached }
        let text = NSAttributedString(string: String(number), attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(text as CFAttributedString)
        if rowNumberLines.count >= Self.lineCacheLimit {
            rowNumberLines.removeAll(keepingCapacity: true)
        }
        rowNumberLines[key] = line
        return line
    }

    private func drawText(_ appearance: DataGridCellAppearance, in rect: NSRect, context: CGContext) {
        guard !appearance.text.isEmpty else { return }
        let availableWidth = appearance.accessory.availableTextWidth(in: rect)
        guard availableWidth > 0 else { return }

        let laidOut = line(for: appearance.text, appearance: appearance)
        let ellipsis = line(for: "\u{2026}", appearance: appearance)
        guard Double(availableWidth) >= ellipsis.width else { return }

        let fitted = laidOut.fitted(to: Double(availableWidth), ellipsis: ellipsis.line)
        let lineToDraw = fitted ?? ellipsis.line

        let font = appearance.font
        let baselineOffset = (rect.height - font.ascender + font.descender - font.leading) / 2 + font.ascender

        let textX = rect.minX + DataGridMetrics.cellHorizontalInset
        let baseline = rect.minY + baselineOffset
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: textX, y: baseline)
        CTLineDraw(lineToDraw, context)
        if let specialCharacters = laidOut.specialCharacters, fitted != nil {
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
        let clipped = text.clipped(toUTF16Units: Self.maximumLaidOutCharacters)
        let key = LineKey(
            shownText: clipped ?? text,
            isClipped: clipped != nil,
            font: font,
            color: appearance.textColor,
            mark: appearance.textMark,
            specialCharacterColor: appearance.specialCharacterColor
        )
        if let cached = lineCache[key] { return cached }

        var laidOut = clipped.map { $0 + "\u{2026}" } ?? text
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
