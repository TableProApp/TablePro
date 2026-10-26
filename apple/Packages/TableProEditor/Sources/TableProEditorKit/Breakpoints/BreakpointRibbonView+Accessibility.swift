//
//  BreakpointRibbonView+Accessibility.swift
//  TableProEditorKit
//

import AppKit
import TableProTextEngine

final class BreakpointElement: NSAccessibilityElement {
    let line: Int
    private let label: String
    private let onPress: (Int) -> Void

    init(line: Int, label: String, onPress: @escaping (Int) -> Void) {
        self.line = line
        self.label = label
        self.onPress = onPress
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func accessibilityLabel() -> String? {
        label
    }

    override func isAccessibilityEnabled() -> Bool {
        true
    }

    override func accessibilityPerformPress() -> Bool {
        onPress(line)
        return true
    }
}

extension BreakpointRibbonView {
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .group
    }

    override func accessibilityLabel() -> String? {
        String(localized: "Breakpoints")
    }

    override func accessibilityValue() -> Any? {
        guard let executionLine = controller?.executionLine else { return nil }
        return String(format: String(localized: "Paused at line %d"), executionLine)
    }

    // One element per breakpoint on screen.
    override func accessibilityChildren() -> [Any]? {
        let breakpoints = controller?.breakpointLines ?? []
        let key = PublishedElementsKey(
            breakpointLines: breakpoints,
            visibleRect: visibleRect,
            windowFrame: window?.frame,
            documentHeight: controller?.textView?.frame.height
        )
        if key == publishedElementsKey {
            return publishedElements
        }
        publishedElementsKey = key

        guard let layoutManager = controller?.textView?.layoutManager else {
            publishedElements = []
            return []
        }

        let format = String(localized: "Breakpoint, line %d")
        let toggle: (Int) -> Void = { [weak self] line in
            self?.controller?.onBreakpointToggle?(line)
        }
        let visible = visibleRect

        publishedElements = breakpoints.sorted().compactMap { lineNumber -> BreakpointElement? in
            guard let line = position(ofLine: lineNumber, in: layoutManager),
                  line.yPos < visible.maxY, line.yPos + line.height > visible.minY else {
                return nil
            }
            let element = BreakpointElement(
                line: lineNumber,
                label: String(format: format, lineNumber),
                onPress: toggle
            )
            element.setAccessibilityParent(self)
            element.setAccessibilityFrame(
                screenRect(CGRect(x: 0, y: line.yPos, width: bounds.width, height: line.height))
            )
            return element
        }

        return publishedElements
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        accessibilityElement(atScreenPoint: point) ?? super.accessibilityHitTest(point)
    }

    // The gutter floats over the text view, so a positional lookup lands on the gutter, which asks here.
    func accessibilityElement(atScreenPoint point: NSPoint) -> BreakpointElement? {
        let children = accessibilityChildren() as? [BreakpointElement] ?? []
        return children.first { $0.accessibilityFrame().contains(point) }
    }

    private func screenRect(_ rect: CGRect) -> CGRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }
}
