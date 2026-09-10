//
//  LineFoldRibbonView+Accessibility.swift
//  CodeEditSourceEditor
//

import AppKit
import CodeEditTextView

/// One fold's disclosure chevron, as assistive technology sees it.
///
/// The chevrons are drawn rather than being views, which is what keeps scrolling a long document cheap, but a drawn
/// control is not a control as far as VoiceOver is concerned. This reports the same thing the chevron shows: a
/// disclosure triangle whose value is whether the block is collapsed, and pressing it toggles the fold through the
/// same call the pointer does.
final class FoldDisclosureElement: NSAccessibilityElement {
    private weak var model: LineFoldModel?
    private let fold: FoldRange
    private let lineNumber: Int

    init(fold: FoldRange, lineNumber: Int, model: LineFoldModel?) {
        self.fold = fold
        self.lineNumber = lineNumber
        self.model = model
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .disclosureTriangle
    }

    override func accessibilityLabel() -> String? {
        "Fold starting on line \(lineNumber + 1)"
    }

    override func accessibilityValue() -> Any? {
        MainActor.assumeIsolated {
            (model?.isCollapsed(fold) ?? false) ? 1 : 0
        }
    }

    override func isAccessibilityEnabled() -> Bool {
        true
    }

    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated {
            guard let model else { return false }
            model.setCollapsed(!model.isCollapsed(fold), for: fold)
            return true
        }
    }
}

extension LineFoldRibbonView {
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .group
    }

    override func accessibilityLabel() -> String? {
        "Code folding"
    }

    /// One element per chevron on screen.
    ///
    /// Built on demand rather than kept in step with the folds, because the fold set changes on every edit and
    /// assistive technology reads this far less often than the document changes.
    override func accessibilityChildren() -> [Any]? {
        guard let model, let layoutManager = model.controller?.textView.layoutManager,
              let range = documentRange(covering: visibleRect, layoutManager: layoutManager) else { return [] }

        let folds = foldsByStartLine(in: range, layoutManager: layoutManager)

        return folds
            .sorted { $0.key < $1.key }
            .compactMap { lineNumber, fold -> FoldDisclosureElement? in
                guard let line = layoutManager.textLineForIndex(lineNumber) else { return nil }
                let element = FoldDisclosureElement(fold: fold, lineNumber: lineNumber, model: model)
                element.setAccessibilityParent(self)
                element.setAccessibilityFrame(
                    screenRect(CGRect(x: 0, y: line.yPos, width: bounds.width, height: line.height))
                )
                return element
            }
    }

    /// A rect in this view's coordinates, in screen coordinates.
    ///
    /// Accessibility frames are always screen rects. Converting through the window rather than setting a frame in
    /// parent space keeps this correct in a flipped view, which this one is.
    private func screenRect(_ rect: CGRect) -> CGRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }
}
