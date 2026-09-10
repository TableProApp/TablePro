//
//  StatementRunRibbonView+Accessibility.swift
//  CodeEditSourceEditor
//

import AppKit
import CodeEditTextView

/// One statement's run control, as assistive technology sees it.
///
/// The controls are drawn rather than being views, which is what keeps scrolling a long document cheap, but a drawn
/// control is not a control as far as VoiceOver is concerned. This reports a button that runs the statement through
/// the same call the pointer does.
final class StatementRunElement: NSAccessibilityElement {
    private let statement: StatementRun
    private let label: String
    private let onRun: (StatementRun) -> Void
    private let isEnabled: Bool

    init(statement: StatementRun, label: String, isEnabled: Bool, onRun: @escaping (StatementRun) -> Void) {
        self.statement = statement
        self.label = label
        self.isEnabled = isEnabled
        self.onRun = onRun
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func accessibilityLabel() -> String? {
        label
    }

    override func isAccessibilityEnabled() -> Bool {
        isEnabled
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onRun(statement)
        return true
    }
}

extension StatementRunRibbonView {
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .group
    }

    override func accessibilityLabel() -> String? {
        accessibilityGroupLabel
    }

    /// One element per control in view.
    ///
    /// Held by the view rather than rebuilt and discarded, because `NSAccessibilityElement` requires the vendor to
    /// keep ownership of the elements it publishes. They are rebuilt whenever the statement set or the visible rect
    /// changes, which is far less often than the document does.
    override func accessibilityChildren() -> [Any]? {
        let key = PublishedElementsKey(statements: statements, visibleRect: visibleRect, isEnabled: isEnabled)
        if key == publishedElementsKey {
            return publishedElements
        }
        publishedElementsKey = key

        guard let layoutManager = controller?.textView?.layoutManager,
              let range = documentRange(covering: visibleRect, layoutManager: layoutManager) else {
            publishedElements = []
            return []
        }

        let anchors = statementsByAnchorLine(in: range, layoutManager: layoutManager)
        let enabled = isEnabled
        let format = accessibilityLabelFormat
        let run: (StatementRun) -> Void = { [weak self] statement in
            self?.onRun?(statement)
        }

        publishedElements = anchors
            .sorted { $0.key < $1.key }
            .compactMap { lineNumber, statement -> StatementRunElement? in
                guard let line = layoutManager.textLineForIndex(lineNumber) else { return nil }
                let element = StatementRunElement(
                    statement: statement,
                    label: String(format: format, lineNumber + 1),
                    isEnabled: enabled,
                    onRun: run
                )
                element.setAccessibilityParent(self)
                element.setAccessibilityFrame(
                    screenRect(CGRect(x: 0, y: line.yPos, width: bounds.width, height: line.height))
                )
                return element
            }

        return publishedElements
    }

    /// Resolves a screen point to the control drawn under it.
    ///
    /// Without this the pointer resolves to this view, which is not the control, so assistive technology and anything
    /// driving the app through it find a button they can read but cannot press. The children are drawn rather than
    /// hosted, so nothing else in the view hierarchy can answer for them.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        accessibilityElement(atScreenPoint: point) ?? super.accessibilityHitTest(point)
    }

    /// The control drawn under a screen point, if one is.
    ///
    /// Exposed because the gutter floats on top of the text view, so a positional lookup resolves to the gutter rather
    /// than to this view, and the gutter has to be able to ask.
    func accessibilityElement(atScreenPoint point: NSPoint) -> StatementRunElement? {
        let children = accessibilityChildren() as? [StatementRunElement] ?? []
        return children.first { $0.accessibilityFrame().contains(point) }
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
