//
//  EmacsEngine.swift
//  TablePro
//

import AppKit
import TableProTextEngine

// The region is the native selection and the mark is its pivot, so an active mark extends with the text view's own
// modify-selection motions and every cursor keeps its own mark.
@MainActor
final class EmacsEngine {
    private var markActive = false
    private var selectionChangeCountAfterLastCommand = 0

    // A click, a Shift-arrow or an edit outside this engine ends the region, as it does in Emacs, even one that leaves
    // the selection where it was.
    func isMarkActive(in textView: TextView) -> Bool {
        if markActive, textView.selectionManager.changeCount != selectionChangeCountAfterLastCommand {
            markActive = false
        }
        return markActive
    }

    func perform(_ command: EmacsCommand, in textView: TextView) {
        let extending = isMarkActive(in: textView)
        defer { selectionChangeCountAfterLastCommand = textView.selectionManager.changeCount }
        switch command {
        case .move(let motion):
            textView.doCommand(by: extending ? motion.extendingSelector : motion.selector)
        case .killLine:
            endRegion(in: textView)
            textView.deleteToEndOfParagraph(nil)
        case .killWord:
            endRegion(in: textView)
            textView.killWordForward(nil)
        case .backwardKillWord:
            endRegion(in: textView)
            textView.killWordBackward(nil)
        case .killRegion:
            markActive = false
            textView.killSelection(nil)
        case .copyRegion:
            textView.copySelectionToKillRing(nil)
            collapseToPoints(in: textView)
            markActive = false
        case .yank:
            endRegion(in: textView)
            textView.yank(nil)
        case .yankPop:
            textView.yankPop(nil)
        case .setMark:
            collapseToPoints(in: textView)
            markActive = true
        case .quit:
            collapseToPoints(in: textView)
            markActive = false
        }
    }

    // Commands that act at point leave an active region first, so they act at point and not on the region.
    private func endRegion(in textView: TextView) {
        guard markActive else { return }
        collapseToPoints(in: textView)
        markActive = false
    }

    private func collapseToPoints(in textView: TextView) {
        let points = textView.selectionManager.textSelections.map { selection in
            let range = selection.range
            let end = NSMaxRange(range)
            let point = selection.pivot == end && !range.isEmpty ? range.location : end
            return NSRange(location: point, length: 0)
        }
        textView.selectionManager.setSelectedRanges(points)
    }
}
