//
//  DraggingTextRenderer.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 11/24/24.
//

import AppKit

class DraggingTextRenderer: NSView {
    let ranges: [NSRange]
    let layoutManager: TextLayoutManager

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        self.frame.size
    }

    init?(ranges: [NSRange], layoutManager: TextLayoutManager) {
        self.ranges = ranges
        self.layoutManager = layoutManager

        assert(!ranges.isEmpty, "Empty ranges not allowed")

        var minY: CGFloat = .infinity
        var maxY: CGFloat = 0.0

        for range in ranges {
            for line in layoutManager.lineStorage.linesInRange(range) {
                minY = min(minY, line.yPos)
                maxY = max(maxY, line.yPos + line.height)
            }
        }

        let frame = CGRect(
            x: layoutManager.edgeInsets.left,
            y: minY,
            width: layoutManager.maxLineWidth,
            height: maxY - minY
        )

        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext,
              let firstRange = ranges.first,
              let minRect = layoutManager.rectForOffset(firstRange.lowerBound) else {
            return
        }

        for range in ranges {
            for line in layoutManager.lineStorage.linesInRange(range) {
                drawLine(line, in: range, yOffset: minRect.minY, context: context)
            }
        }
    }

    private func drawLine(
        _ line: TextLineStorage<TextLine>.TextLinePosition,
        in selectedRange: NSRange,
        yOffset: CGFloat,
        context: CGContext
    ) {
        let renderer = LineFragmentRenderer(
            textStorage: layoutManager.textStorage,
            invisibleCharacterDelegate: layoutManager.invisibleCharacterDelegate
        )
        for fragment in line.data.lineFragments {
            guard let fragmentRange = fragment.range.shifted(by: line.range.location),
                  fragmentRange.intersection(selectedRange) != nil else {
                continue
            }
            let fragmentYPos = line.yPos + fragment.yPos - yOffset
            renderer.draw(lineFragment: fragment.data, in: context, yPos: fragmentYPos)

            // Clear text that's not selected
            if fragmentRange.contains(selectedRange.lowerBound) {
                let relativeOffset = selectedRange.lowerBound - line.range.lowerBound
                let selectionXPos = layoutManager.characterXPosition(in: fragment.data, for: relativeOffset)
                context.clear(
                    CGRect(
                        x: 0.0,
                        y: fragmentYPos,
                        width: selectionXPos,
                        height: fragment.height
                    ).pixelAligned
                )
            }

            if fragmentRange.contains(selectedRange.upperBound) {
                let relativeOffset = selectedRange.upperBound - line.range.lowerBound
                let selectionXPos = layoutManager.characterXPosition(in: fragment.data, for: relativeOffset)
                context.clear(
                    CGRect(
                        x: selectionXPos,
                        y: fragmentYPos,
                        width: frame.width - selectionXPos,
                        height: fragment.height
                    ).pixelAligned
                )
            }
        }
    }
}
