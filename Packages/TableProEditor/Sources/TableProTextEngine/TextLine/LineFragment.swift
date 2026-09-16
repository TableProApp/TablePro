//
//  LineFragment.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 6/29/23.
//

import AppKit
import TableProTextEngineObjC

/// A ``LineFragment`` represents a subrange of characters in a line. Every text line contains at least one line
/// fragments, and any lines that need to be broken due to width constraints will contain more than one fragment.
public final class LineFragment: Identifiable, Equatable {
    public struct FragmentContent: Equatable {
        public enum Content: Equatable {
            case text(line: CTLine)
            case attachment(attachment: AnyTextAttachment)
        }

        public let data: Content
        public let width: CGFloat

        public var length: Int {
            switch data {
            case .text(let line):
                CTLineGetStringRange(line).length
            case .attachment(let attachment):
                attachment.range.length
            }
        }

#if DEBUG
        var isText: Bool {
            switch data {
            case .text:
                true
            case .attachment:
                false
            }
        }
#endif
    }

    public struct ContentPosition {
        let xPos: CGFloat
        let offset: Int
    }

    public let id = UUID()
    public var documentRange: NSRange = .notFound
    public var contents: [FragmentContent] {
        didSet {
            drawingPlans = [ClippedLineDrawing.Plan?](repeating: nil, count: contents.count)
        }
    }
    public var width: CGFloat
    public var height: CGFloat
    public var descent: CGFloat
    public var scaledHeight: CGFloat
    public internal(set) var specialCharacters: [SpecialCharacterMark] = [] {
        didSet {
            specialCharactersRunLeftToRight = zip(specialCharacters, specialCharacters.dropFirst())
                .allSatisfy { $0.minX <= $1.minX && $0.maxX <= $1.maxX }
        }
    }

    /// True when the marks in ``specialCharacters`` are ordered by their position, which every fragment without
    /// bidirectional text is. Lets a draw find the visible marks by binary search rather than by walking them all.
    private var specialCharactersRunLeftToRight = true

    /// What clip-bounded drawing each text content allows, built on first draw.
    ///
    /// A plan describes one `CTLine`, so it lives exactly as long as the ``contents`` holding that line. Building one
    /// costs less than the single `CTLineDraw` it replaces, but a redraw per exposed strip cannot afford to rebuild
    /// it, and a renderer-side cache would have to evict entries this fragment already knows the lifetime of.
    private var drawingPlans: [ClippedLineDrawing.Plan?]

    /// The difference between the real text height and the scaled height
    public var heightDifference: CGFloat {
        scaledHeight - height
    }

    init(
        contents: [FragmentContent],
        width: CGFloat,
        height: CGFloat,
        descent: CGFloat,
        lineHeightMultiplier: CGFloat
    ) {
        self.contents = contents
        self.drawingPlans = [ClippedLineDrawing.Plan?](repeating: nil, count: contents.count)
        self.width = width
        self.height = height
        self.descent = descent
        self.scaledHeight = height * lineHeightMultiplier
    }

    public static func == (lhs: LineFragment, rhs: LineFragment) -> Bool {
        lhs.id == rhs.id
    }

    /// The special character marks that can appear between two x positions.
    ///
    /// Narrows the array by binary search when the marks run left to right, and hands back all of them when they do
    /// not. Callers still have to test each mark against their own bounds.
    /// - Parameters:
    ///   - minX: The left edge of the region being drawn, in fragment coordinates.
    ///   - maxX: The right edge of the region being drawn, in fragment coordinates.
    /// - Returns: The marks to consider drawing.
    func specialCharacters(from minX: CGFloat, to maxX: CGFloat) -> ArraySlice<SpecialCharacterMark> {
        guard specialCharactersRunLeftToRight else { return specialCharacters[...] }
        let start = firstSpecialCharacterIndex { $0.maxX >= minX }
        let end = firstSpecialCharacterIndex(from: start) { $0.minX > maxX }
        return specialCharacters[start..<end]
    }

    private func firstSpecialCharacterIndex(
        from lowerBound: Int = 0,
        where predicate: (SpecialCharacterMark) -> Bool
    ) -> Int {
        var low = lowerBound
        var high = specialCharacters.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(specialCharacters[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }

    /// The clip-bounded drawing plan for one of this fragment's text contents, built on first use.
    /// - Parameters:
    ///   - index: The index of the content in ``contents``.
    ///   - ctLine: The line that content draws.
    /// - Returns: What that line allows a clip-bounded draw to do.
    func clippedDrawingPlan(forContentAt index: Int, ctLine: CTLine) -> ClippedLineDrawing.Plan {
        guard drawingPlans.indices.contains(index) else {
            return ClippedLineDrawing.Plan(ctLine: ctLine)
        }
        if let plan = drawingPlans[index] {
            return plan
        }
        let plan = ClippedLineDrawing.Plan(ctLine: ctLine)
        drawingPlans[index] = plan
        return plan
    }

    /// Finds the x position of the offset in the string the fragment represents.
    ///
    /// Callers outside this class should prefer ``TextLayoutManager/characterXPosition(in:for:)``, which gives the
    /// render delegate a chance to override the position.
    ///
    /// - Parameter offset: The offset, relative to the start of the *line*.
    /// - Returns: The x position of the character in the drawn line, from the left.
    func xPosition(for offset: Int) -> CGFloat {
        guard let (content, position) = findContent(at: offset) else {
            return width
        }
        switch content.data {
        case .text(let ctLine):
            return CTLineGetOffsetForStringIndex(
                ctLine,
                CTLineGetStringRange(ctLine).location + offset - position.offset,
                nil
            ) + position.xPos
        case .attachment:
            return position.xPos
        }
    }

    package func findContent(at location: Int) -> (content: FragmentContent, position: ContentPosition)? {
        var position = ContentPosition(xPos: 0, offset: 0)

        for content in contents {
            let length = content.length
            let width = content.width

            if (position.offset..<(position.offset + length)).contains(location) {
                return (content, position)
            }

            position = ContentPosition(xPos: position.xPos + width, offset: position.offset + length)
        }

        return nil
    }

    package func findContent(atX xPos: CGFloat) -> (content: FragmentContent, position: ContentPosition)? {
        var position = ContentPosition(xPos: 0, offset: 0)

        for content in contents {
            let length = content.length
            let width = content.width

            if (position.xPos..<(position.xPos + width)).contains(xPos) {
                return (content, position)
            }

            position = ContentPosition(xPos: position.xPos + width, offset: position.offset + length)
        }

        return nil
    }
}
