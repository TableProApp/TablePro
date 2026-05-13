//
//  VimEngine+Repeat.swift
//  TablePro
//

import Foundation

extension VimEngine {
    func noteEdit(at offset: Int, in buffer: VimTextBuffer) {
        let line = buffer.lineAndColumn(forOffset: offset).line
        if let last = lastEditedLine, last == line {
            editsOnCurrentLine += 1
        } else {
            editsOnCurrentLine = 1
            lastEditedLine = line
        }
    }

    func recordDot(_ kind: VimDotKind) {
        lastDotKind = kind
    }

    func replayLastDot(count: Int, in buffer: VimTextBuffer) {
        guard let kind = lastDotKind else { return }
        for _ in 0..<count {
            switch kind {
            case .deleteCharForward(let original):
                deleteCharUnderCursor(original, in: buffer)
            case .deleteCharBackward(let original):
                deleteCharBeforeCursor(original, in: buffer)
            case .operatorWithMotion(let op, let motion, let shift, let original):
                operatorCount = 0
                countPrefix = original
                pendingOperator = op
                _ = processNormal(motion, shift: shift)
            case .operatorDoubled(let op, let original):
                switch op {
                case .delete: deleteLine(original, in: buffer)
                case .yank: yankLine(original, in: buffer)
                case .change: changeLine(original, in: buffer)
                default: break
                }
            case .toggleCase(let original):
                toggleCaseUnderCursor(original, in: buffer)
            case .joinLines(let withSpace, let original):
                joinLines(original, withSpace: withSpace, in: buffer)
            case .replaceChar(let ch, _):
                pendingReplaceChar = true
                _ = executeReplaceChar(ch, in: buffer)
            }
        }
    }
}
