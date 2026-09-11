//
//  SpecialCharacterMarksLayer.swift
//  CodeEditTextView
//

import AppKit
import QuartzCore

final class SpecialCharacterMarksLayer: CALayer {
    private let marks: [SpecialCharacterMark]
    private let color: NSColor

    init(marks: [SpecialCharacterMark], color: NSColor) {
        self.marks = marks
        self.color = color
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        let source = layer as? SpecialCharacterMarksLayer
        self.marks = source?.marks ?? []
        self.color = source?.color ?? .clear
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        if !contentsAreFlipped() {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        for mark in marks {
            SpecialCharacterMarkRenderer.draw(
                mark,
                from: mark.minX,
                to: mark.maxX,
                top: 0,
                height: bounds.height,
                color: color,
                in: context
            )
        }
    }
}
