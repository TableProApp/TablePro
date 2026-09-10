//
//  LineFoldPlaceholderClickTests.swift
//  CodeEditSourceEditor
//

import AppKit
import CodeEditTextView
import Testing
@testable import CodeEditSourceEditor

/// A placeholder stands in for code the reader asked to hide and now wants back, so one click brings it back rather
/// than selecting it. Attachments that stand in for content of their own keep the selecting behaviour.
@MainActor
struct LineFoldPlaceholderClickTests {
    private final class PlainAttachment: TextAttachment {
        var width: CGFloat = 10
        var isSelected: Bool = false
        func draw(in context: CGContext, rect: NSRect) {}
    }

    @Test("A fold placeholder opens on a single click")
    func placeholderOpensOnOneClick() {
        let fold = FoldRange(id: 1, depth: 1, range: 0..<10, isCollapsed: true)
        let placeholder = LineFoldPlaceholder(
            delegate: nil,
            fold: fold,
            charWidth: 7,
            label: "…",
            font: .monospacedSystemFont(ofSize: 12, weight: .regular)
        )

        #expect(placeholder.activatesOnSingleClick)
    }

    @Test("Other attachments still select on a single click")
    func plainAttachmentKeepsSelecting() {
        #expect(PlainAttachment().activatesOnSingleClick == false)
    }
}
