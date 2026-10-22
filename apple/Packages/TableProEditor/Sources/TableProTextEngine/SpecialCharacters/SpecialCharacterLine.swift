//
//  SpecialCharacterLine.swift
//  TableProTextEngine
//

import AppKit

// The editor's marks for a view that draws one line itself, such as a grid cell.
public struct SpecialCharacterLine {
    public let line: CTLine
    public let marks: [SpecialCharacterMark]

    public init(_ string: NSAttributedString, style: SpecialCharacterStyle) {
        let display = SpecialCharacterDisplay.make(from: string, style: style)
        let line = CTLineCreateWithAttributedString(display.string)
        self.line = line
        marks = SpecialCharacterGeometry.positioned(display.marks, in: line)
    }

    // `drawn` is this line or an end truncation of it. A right-to-left line moves what it keeps, so
    // the marks are placed again, and the ones the ellipsis replaced are dropped.
    public func marks(drawnIn drawn: CTLine) -> [SpecialCharacterMark] {
        guard drawn !== line, !marks.isEmpty else { return marks }
        let length = CTLineGetStringRange(line).length
        let runs = CTLineGetGlyphRuns(drawn) as? [CTRun] ?? []
        let cut = runs.map(CTRunGetStringRange)
            .filter { $0.location + $0.length == length }
            .map(\.location)
            .min() ?? length
        let kept = marks.filter { $0.offset + $0.length <= cut }
        return SpecialCharacterGeometry.positioned(kept, in: drawn)
    }

    public static func draw(
        _ marks: [SpecialCharacterMark],
        fromX x: CGFloat,
        top: CGFloat,
        height: CGFloat,
        in context: CGContext
    ) {
        for mark in marks {
            SpecialCharacterMarkRenderer.draw(
                mark,
                from: x + mark.minX,
                to: x + mark.maxX,
                top: top,
                height: height,
                color: mark.color,
                in: context
            )
        }
    }
}

// One mark as an inline attachment, for a text view that swaps it in for its character.
public struct SpecialCharacterMarkImage {
    public let image: NSImage
    public let bounds: CGRect

    public init(_ classified: ClassifiedSpecialCharacter, in text: NSString, font: NSFont, color: NSColor) {
        let width: CGFloat
        switch classified.character {
        case .marker(let label):
            width = SpecialCharacterMetrics.markerWidth(label: label, font: font)
        case .blankSpace:
            let space = NSAttributedString(string: text.substring(with: classified.range), attributes: [.font: font])
            width = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(space), nil, nil, nil))
        }
        let height = font.ascender - font.descender
        bounds = CGRect(x: 0, y: font.descender, width: width, height: height)

        let mark = SpecialCharacterMark(
            offset: 0,
            length: classified.range.length,
            character: classified.character,
            font: font,
            color: color
        )
        image = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            SpecialCharacterMarkRenderer.draw(
                mark,
                from: rect.minX,
                to: rect.maxX,
                top: rect.minY,
                height: rect.height,
                color: color,
                in: context
            )
            return true
        }
    }
}
