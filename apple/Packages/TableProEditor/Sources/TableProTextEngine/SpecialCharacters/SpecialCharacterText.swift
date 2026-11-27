//
//  SpecialCharacterText.swift
//  TableProTextEngine
//

import AppKit

// The editor's marks for a view that breaks a value into lines itself, such as a grid cell that wraps.
public struct SpecialCharacterText {
    // As long as the source, unit for unit, so an offset into one is an offset into the other.
    public let string: NSAttributedString
    public let marks: [SpecialCharacterMark]

    public init(_ string: NSAttributedString, style: SpecialCharacterStyle) {
        let display = SpecialCharacterDisplay.make(from: string, style: style)
        self.string = display.string
        marks = display.marks
    }

    // `line` shows `string` from `start`: typeset from it there, or laid out from that part alone.
    // `drawn` is `line` or an end truncation of it, which drops the marks the ellipsis replaced.
    public func marks(from start: Int, in line: CTLine, drawnAs drawn: CTLine) -> [SpecialCharacterMark] {
        guard !marks.isEmpty else { return [] }
        let range = CTLineGetStringRange(line)
        let lineEnd = range.location + range.length
        var shownEnd = lineEnd
        if drawn !== line {
            let runs = CTLineGetGlyphRuns(drawn) as? [CTRun] ?? []
            shownEnd = runs.map(CTRunGetStringRange)
                .filter { $0.location + $0.length == lineEnd }
                .map(\.location)
                .min() ?? lineEnd
        }
        let end = start + shownEnd - range.location
        let shown = marks
            .filter { $0.offset >= start && $0.offset + $0.length <= end }
            .map { $0.offset(by: -start) }
        return SpecialCharacterGeometry.positioned(shown, in: drawn)
    }
}
