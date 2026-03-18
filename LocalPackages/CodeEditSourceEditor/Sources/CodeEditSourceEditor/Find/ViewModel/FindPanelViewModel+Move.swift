//
//  FindPanelViewModel+Move.swift
//  CodeEditSourceEditor
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
            self.currentFindMatchIndex = 0
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

    private func showWrapNotification(forwards: Bool, error: Bool, targetView: NSView) {
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
