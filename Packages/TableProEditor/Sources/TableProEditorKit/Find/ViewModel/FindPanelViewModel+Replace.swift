//
//  FindPanelViewModel+Replace.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 4/18/25.
//

import Foundation
import TableProTextEngine

extension FindPanelViewModel {
    /// Replaces the current match and selects the next one, the native find bar's Replace
    /// (`NSTextFinder.Action.replaceAndFind`).
    ///
    /// Matches are searched for again after the edit rather than shifted by hand: a pattern can stop or start matching
    /// around the replacement, and a stored range past the end of the text is a crash in the text storage.
    func replace() {
        guard let target, canReplace,
              let index = currentFindMatchIndex, findMatches.indices.contains(index) else {
            return
        }

        let text = target.textView.string
        guard let match = searchResults().first(where: { $0.range == findMatches[index] }) else {
            find()
            return
        }

        let replacement = replacementString(for: match, in: text)
        guard applyReplacements([TextReplacement(range: match.range, string: replacement)], to: target) else {
            return
        }

        let resumeLocation = match.range.location + (replacement as NSString).length
        findMatches = searchResults().map(\.range)
        if let next = findMatches.firstIndex(where: { $0.location >= resumeLocation }) {
            currentFindMatchIndex = next
        } else if findMatches.isEmpty {
            currentFindMatchIndex = nil
        } else if wrapAround {
            currentFindMatchIndex = 0
            showWrapNotification(forwards: true, error: false, targetView: target.findPanelTargetView)
        } else {
            currentFindMatchIndex = nil
            showWrapNotification(forwards: true, error: true, targetView: target.findPanelTargetView)
        }

        addMatchEmphases(flashCurrent: true)
    }

    /// Replaces every match in one undoable edit, the native find bar's All (`NSTextFinder.Action.replaceAll`). Each
    /// match is replaced once, so text a replacement inserts is never searched again.
    func replaceAll() {
        guard let target, canReplace else { return }

        let text = target.textView.string
        let replacements = searchResults().map {
            TextReplacement(range: $0.range, string: replacementString(for: $0, in: text))
        }
        guard applyReplacements(replacements, to: target) else { return }

        findMatches = searchResults().map(\.range)
        currentFindMatchIndex = nil
        if isFocused {
            addMatchEmphases(flashCurrent: false)
        }
    }

    /// The edit's own text change would search again once per edit, so the search waits for the edit to finish. The
    /// highlights come off first: each one is re-measured on every edit, which made a large Replace All take seconds.
    private func applyReplacements(_ replacements: [TextReplacement], to target: FindPanelTarget) -> Bool {
        clearMatchEmphases()
        isReplacingMatches = true
        defer { isReplacingMatches = false }
        return target.replaceFindMatches(replacements)
    }

    /// A regular expression's replacement is a template, so `$1` inserts the first capture group, as the data-file
    /// Replace reads it. Every other method inserts the replacement as typed.
    private func replacementString(for match: NSTextCheckingResult, in text: String) -> String {
        guard findMethod == .regularExpression, let regex = match.regularExpression else { return replaceText }
        return regex.replacementString(for: match, in: text, offset: 0, template: replaceText)
    }
}
