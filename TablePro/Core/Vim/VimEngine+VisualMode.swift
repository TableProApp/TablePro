//
//  VimEngine+VisualMode.swift
//  TablePro
//

import Foundation

extension VimEngine {
    func processVisual(_ char: Character, shift: Bool) -> Bool { // swiftlint:disable:this function_body_length
        guard let buffer else { return false }

        if pendingReplaceCharForVisual {
            pendingReplaceCharForVisual = false
            if char == "\u{1B}" { return true }
            replaceVisualSelectionWithChar(char, in: buffer)
            return true
        }
        if pendingTextObject {
            pendingTextObject = false
            if char == "\u{1B}" { return true }
            return executeTextObject(char, around: pendingTextObjectAround, in: buffer)
        }

        let isLinewise: Bool
        if case .visual(let lw) = mode { isLinewise = lw } else { isLinewise = false }

        if pendingG {
            pendingG = false
            if char == "g" {
                updateVisualSelection(cursorPos: 0, linewise: isLinewise, in: buffer)
                return true
            }
            if char == "J" {
                joinSelectedLines(withSpace: false, in: buffer)
                return true
            }
            return true
        }

        switch char {
        case "\u{1B}":
            recordVisualSelection(linewise: isLinewise, in: buffer)
            setMode(.normal)
            let pos = buffer.selectedRange().location
            buffer.setSelectedRange(NSRange(location: pos, length: 0))
            return true

        case "h", "j", "k", "l", "w", "b", "e", "0", "$", "G", "^", "_":
            let cursorPos = visualCursorEnd(buffer: buffer)
            let newPos: Int
            switch char {
            case "h": newPos = max(0, cursorPos - 1)
            case "l": newPos = min(buffer.length, cursorPos + 1)
            case "j":
                let (line, col) = buffer.lineAndColumn(forOffset: cursorPos)
                let targetLine = min(buffer.lineCount - 1, line + 1)
                newPos = buffer.offset(forLine: targetLine, column: col)
            case "k":
                let (line, col) = buffer.lineAndColumn(forOffset: cursorPos)
                let targetLine = max(0, line - 1)
                newPos = buffer.offset(forLine: targetLine, column: col)
            case "w": newPos = buffer.wordBoundary(forward: true, from: cursorPos)
            case "b": newPos = buffer.wordBoundary(forward: false, from: cursorPos)
            case "e": newPos = buffer.wordEnd(from: cursorPos)
            case "0":
                let lineRange = buffer.lineRange(forOffset: cursorPos)
                newPos = lineRange.location
            case "$":
                let lineRange = buffer.lineRange(forOffset: cursorPos)
                let lineEnd = lineRange.location + lineRange.length
                newPos = lineEnd > lineRange.location
                    && lineEnd <= buffer.length
                    && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
            case "G":
                newPos = max(0, buffer.length - 1)
            case "^", "_":
                newPos = firstNonBlankOffset(from: cursorPos, in: buffer)
            default:
                newPos = cursorPos
            }
            updateVisualSelection(cursorPos: newPos, linewise: isLinewise, in: buffer)
            return true

        case "g":
            pendingG = true
            return true

        case "J":
            joinSelectedLines(withSpace: true, in: buffer)
            return true

        case "o":
            swapVisualAnchorAndCursor(in: buffer, linewise: isLinewise)
            return true

        case "~":
            applyCaseToVisualSelection(.toggleCase, linewise: isLinewise, in: buffer)
            return true
        case "u":
            applyCaseToVisualSelection(.lowercase, linewise: isLinewise, in: buffer)
            return true
        case "U":
            applyCaseToVisualSelection(.uppercase, linewise: isLinewise, in: buffer)
            return true

        case "r":
            pendingReplaceCharForVisual = true
            return true

        case "i":
            pendingTextObject = true
            pendingTextObjectAround = false
            return true
        case "a":
            pendingTextObject = true
            pendingTextObjectAround = true
            return true
        case "I":
            let sel = buffer.selectedRange()
            buffer.setSelectedRange(NSRange(location: sel.location, length: 0))
            setMode(.insert)
            return true
        case "A":
            let sel = buffer.selectedRange()
            let endPos = sel.location + sel.length
            let clamped = min(endPos, buffer.length)
            buffer.setSelectedRange(NSRange(location: clamped, length: 0))
            setMode(.insert)
            return true

        case "p", "P":
            pasteOverVisualSelection(in: buffer)
            return true

        case "d", "x":
            let sel = buffer.selectedRange()
            recordVisualSelection(linewise: isLinewise, in: buffer)
            if sel.length > 0 {
                writeToActiveRegister(text: buffer.string(in: sel), linewise: isLinewise, asDelete: true)
                adjustMarksForEdit(in: sel, replacementLength: 0)
                buffer.replaceCharacters(in: sel, with: "")
            }
            setMode(.normal)
            return true

        case "y":
            let sel = buffer.selectedRange()
            recordVisualSelection(linewise: isLinewise, in: buffer)
            if sel.length > 0 {
                writeToActiveRegister(text: buffer.string(in: sel), linewise: isLinewise, asDelete: false)
            }
            setMode(.normal)
            buffer.setSelectedRange(NSRange(location: sel.location, length: 0))
            return true

        case "c":
            let sel = buffer.selectedRange()
            if sel.length > 0 {
                register.text = buffer.string(in: sel)
                register.isLinewise = isLinewise
                register.syncToPasteboard()
                if isLinewise {
                    let trimmed = sel.length > 0
                        && sel.location + sel.length - 1 < buffer.length
                        && buffer.character(at: sel.location + sel.length - 1) == 0x0A
                        ? NSRange(location: sel.location, length: sel.length - 1) : sel
                    buffer.replaceCharacters(in: trimmed, with: "")
                    buffer.setSelectedRange(NSRange(location: sel.location, length: 0))
                } else {
                    buffer.replaceCharacters(in: sel, with: "")
                }
            }
            setMode(.insert)
            return true

        case "v":
            if isLinewise {
                setMode(.visual(linewise: false))
                updateVisualSelection(cursorPos: visualCursorEnd(buffer: buffer), linewise: false, in: buffer)
            } else {
                setMode(.normal)
                let pos = buffer.selectedRange().location
                buffer.setSelectedRange(NSRange(location: pos, length: 0))
            }
            return true

        case "V":
            if isLinewise {
                setMode(.normal)
                let pos = buffer.selectedRange().location
                buffer.setSelectedRange(NSRange(location: pos, length: 0))
            } else {
                setMode(.visual(linewise: true))
                updateVisualSelection(cursorPos: visualCursorEnd(buffer: buffer), linewise: true, in: buffer)
            }
            return true

        default:
            return true
        }
    }

    func visualCursorEnd(buffer: VimTextBuffer) -> Int {
        let sel = buffer.selectedRange()
        if sel.location == visualAnchor {
            return sel.location + max(sel.length, 1) - 1
        }
        return sel.location
    }

    func updateVisualSelection(cursorPos: Int, linewise: Bool, in buffer: VimTextBuffer) {
        cursorOffset = cursorPos
        let start = min(visualAnchor, cursorPos)
        let end = max(visualAnchor, cursorPos)

        if linewise {
            let startLineRange = buffer.lineRange(forOffset: start)
            let endLineRange = buffer.lineRange(forOffset: end)
            let lineStart = startLineRange.location
            let lineEnd = endLineRange.location + endLineRange.length
            buffer.setSelectedRange(NSRange(location: lineStart, length: lineEnd - lineStart))
        } else {
            let length = end - start + (end < buffer.length ? 1 : 0)
            buffer.setSelectedRange(NSRange(location: start, length: length))
        }
    }

    func swapVisualAnchorAndCursor(in buffer: VimTextBuffer, linewise: Bool) {
        let sel = buffer.selectedRange()
        let cursor = visualCursorEnd(buffer: buffer)
        let otherEnd = cursor == sel.location
            ? sel.location + max(0, sel.length - 1)
            : sel.location
        visualAnchor = cursor
        cursorOffset = otherEnd
        updateVisualSelection(cursorPos: otherEnd, linewise: linewise, in: buffer)
    }

    func applyCaseToVisualSelection(_ op: VimOperator, linewise: Bool, in buffer: VimTextBuffer) {
        let sel = buffer.selectedRange()
        guard sel.length > 0 else { setMode(.normal); return }
        let original = buffer.string(in: sel)
        let transformed: String
        switch op {
        case .lowercase: transformed = original.lowercased()
        case .uppercase: transformed = original.uppercased()
        case .toggleCase: transformed = toggleCaseTransform(original)
        default: return
        }
        buffer.replaceCharacters(in: sel, with: transformed)
        buffer.setSelectedRange(NSRange(location: sel.location, length: 0))
        setMode(.normal)
    }

    func replaceVisualSelectionWithChar(_ char: Character, in buffer: VimTextBuffer) {
        let sel = buffer.selectedRange()
        guard sel.length > 0 else { setMode(.normal); return }
        var replacement = ""
        replacement.reserveCapacity(sel.length)
        for i in 0..<sel.length {
            let original = buffer.character(at: sel.location + i)
            if original == 0x0A {
                replacement.append("\n")
            } else {
                replacement.append(char)
            }
        }
        buffer.replaceCharacters(in: sel, with: replacement)
        buffer.setSelectedRange(NSRange(location: sel.location, length: 0))
        setMode(.normal)
    }

    func pasteOverVisualSelection(in buffer: VimTextBuffer) {
        let sel = buffer.selectedRange()
        let text = register.text
        guard sel.length > 0 else { setMode(.normal); return }
        buffer.replaceCharacters(in: sel, with: text)
        let newPos = sel.location + (text as NSString).length - 1
        buffer.setSelectedRange(NSRange(location: max(sel.location, newPos), length: 0))
        setMode(.normal)
    }
}
