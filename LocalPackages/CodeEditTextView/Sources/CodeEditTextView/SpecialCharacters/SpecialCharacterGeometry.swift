//
//  SpecialCharacterGeometry.swift
//  CodeEditTextView
//

import AppKit

enum SpecialCharacterGeometry {
    static func positioned(_ marks: [SpecialCharacterMark], in fragment: LineFragment) -> [SpecialCharacterMark] {
        guard !marks.isEmpty else { return [] }
        var positioned = marks
        var markIndex = 0
        var contentStart = 0
        var contentX: CGFloat = 0
        for content in fragment.contents {
            let contentEnd = contentStart + content.length
            let firstMark = markIndex
            while markIndex < positioned.count, positioned[markIndex].offset < contentEnd {
                markIndex += 1
            }
            if case .text(let ctLine) = content.data, firstMark < markIndex {
                place(&positioned[firstMark..<markIndex], in: ctLine, contentStart: contentStart, contentX: contentX)
            }
            contentStart = contentEnd
            contentX += content.width
        }
        return positioned
    }

    static func positioned(_ marks: [SpecialCharacterMark], in ctLine: CTLine) -> [SpecialCharacterMark] {
        guard !marks.isEmpty else { return [] }
        var positioned = marks
        place(&positioned[...], in: ctLine, contentStart: 0, contentX: 0)
        return positioned
    }

    private static func place(
        _ marks: inout ArraySlice<SpecialCharacterMark>,
        in ctLine: CTLine,
        contentStart: Int,
        contentX: CGFloat
    ) {
        let lineStart = CTLineGetStringRange(ctLine).location
        var wanted = Set<Int>()
        for mark in marks {
            wanted.insert(lineStart + mark.offset - contentStart)
            wanted.insert(lineStart + mark.offset - contentStart + mark.length - 1)
        }
        var leading: [Int: CGFloat] = [:]
        var trailing: [Int: CGFloat] = [:]
        CTLineEnumerateCaretOffsets(ctLine) { offset, characterIndex, isLeadingEdge, _ in
            guard wanted.contains(characterIndex) else { return }
            if isLeadingEdge {
                leading[characterIndex] = leading[characterIndex] ?? offset
            } else {
                trailing[characterIndex] = offset
            }
        }
        for index in marks.indices {
            let first = lineStart + marks[index].offset - contentStart
            let last = first + marks[index].length - 1
            let start = leading[first] ?? 0
            let end = trailing[last] ?? start
            marks[index].minX = contentX + min(start, end)
            marks[index].maxX = contentX + max(start, end)
        }
    }
}
