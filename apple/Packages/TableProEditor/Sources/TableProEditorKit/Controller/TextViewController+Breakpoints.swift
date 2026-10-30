//
//  TextViewController+Breakpoints.swift
//  TableProEditorKit
//

import AppKit

extension TextViewController {
    func breakpointLinesDidChange() {
        gutterView?.breakpointRibbon.needsDisplay = true
    }

    func executionLineDidChange() {
        (textView as? SourceEditorTextView)?.executionLine = executionLine
        if let ribbon = gutterView?.breakpointRibbon {
            ribbon.needsDisplay = true
            NSAccessibility.post(element: ribbon, notification: .valueChanged)
        }
        executionLineNeedsReveal = executionLine != nil
        revealExecutionLineIfNeeded()
    }

    // Before the view has a size or the source has arrived it stays pending; `viewDidAppear` and `setText` retry.
    func revealExecutionLineIfNeeded() {
        guard executionLineNeedsReveal,
              let executionLine,
              let textView,
              isViewLoaded, scrollView != nil, view.window != nil,
              let line = textView.layoutManager.lineStorage.getLine(atIndex: executionLine - 1) else {
            return
        }
        executionLineNeedsReveal = false
        revealFold(containing: line.range.location)
        // A just-replaced document has not grown the view to its height yet, which would clamp the scroll.
        textView.updateFrameIfNeeded()
        textView.scrollToRange(NSRange(location: line.range.location, length: 0), center: true)
    }
}
