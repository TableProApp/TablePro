//
//  FindPanelViewModel+Move.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 4/18/25.
//

import AppKit

extension FindPanelViewModel {
    func moveToNextMatch() {
        moveMatch(forwards: true)
    }

    func moveToPreviousMatch() {
        moveMatch(forwards: false)
    }

    private func moveMatch(forwards: Bool) {
        guard let target = target else { return }

        guard !findMatches.isEmpty else {
            showWrapNotification(forwards: forwards, error: true, targetView: target.findPanelTargetView)
            return
        }

        // From here on out we want to emphasize the result no matter what
        defer {
            if isTargetFirstResponder {
                flashCurrentMatch()
            } else {
                addMatchEmphases(flashCurrent: isTargetFirstResponder)
            }
        }

        guard let currentFindMatchIndex else {
            moveFromCaret(forwards: forwards, targetView: target.findPanelTargetView)
            return
        }

        let isAtLimit = forwards ? currentFindMatchIndex == findMatches.count - 1 : currentFindMatchIndex == 0
        guard !isAtLimit || wrapAround else {
            showWrapNotification(forwards: forwards, error: true, targetView: target.findPanelTargetView)
            return
        }

        self.currentFindMatchIndex = if forwards {
            (currentFindMatchIndex + 1) % findMatches.count
        } else {
            (currentFindMatchIndex - 1 + (findMatches.count)) % findMatches.count
        }
        if isAtLimit {
            showWrapNotification(forwards: forwards, error: false, targetView: target.findPanelTargetView)
        }
    }

    /// With no current match, which is where a search ends after the last replacement, the next match is the one past
    /// the caret, as the native find bar searches from the selection. Wrap Around decides what happens past the end.
    private func moveFromCaret(forwards: Bool, targetView: NSView) {
        let caret = target?.cursorPositions.first?.range ?? NSRange(location: 0, length: 0)
        let nearest = forwards
            ? findMatches.firstIndex { $0.location >= NSMaxRange(caret) }
            : findMatches.lastIndex { NSMaxRange($0) <= caret.location }
        if let nearest {
            currentFindMatchIndex = nearest
        } else if wrapAround {
            currentFindMatchIndex = forwards ? 0 : findMatches.count - 1
            showWrapNotification(forwards: forwards, error: false, targetView: targetView)
        } else {
            showWrapNotification(forwards: forwards, error: true, targetView: targetView)
        }
    }

    func showWrapNotification(forwards: Bool, error: Bool, targetView: NSView) {
        if error {
            NSSound.beep()
        }
        BezelNotification.show(
            symbolName: error ?
            forwards ? "arrow.down.to.line" : "arrow.up.to.line"
            : forwards
                ? "arrow.trianglehead.topright.capsulepath.clockwise"
                : "arrow.trianglehead.bottomleft.capsulepath.clockwise",
            over: targetView
        )
    }
}
