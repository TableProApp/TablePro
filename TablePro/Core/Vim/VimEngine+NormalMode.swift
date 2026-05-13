//
//  VimEngine+NormalMode.swift
//  TablePro
//

import Foundation

extension VimEngine {
    func processNormal(_ char: Character, shift: Bool) -> Bool { // swiftlint:disable:this function_body_length cyclomatic_complexity
        guard let buffer else { return false }

        if let consumed = handleNormalControl(char, in: buffer) {
            return consumed
        }

        if let req = pendingFindChar {
            pendingFindChar = nil
            if char == "\u{1B}" { return true }
            return executeFindChar(char, request: req, in: buffer)
        }
        if pendingReplaceChar {
            pendingReplaceChar = false
            if char == "\u{1B}" { return true }
            return executeReplaceChar(char, in: buffer)
        }
        if pendingMarkSet {
            pendingMarkSet = false
            if char == "\u{1B}" { return true }
            marks[char] = buffer.selectedRange().location
            return true
        }
        if let exact = pendingMarkJumpExact {
            pendingMarkJumpExact = nil
            if char == "\u{1B}" { return true }
            jumpToMark(char, exact: exact, in: buffer)
            return true
        }
        if pendingRegisterSelect {
            pendingRegisterSelect = false
            if char == "\u{1B}" { return true }
            selectedRegister = char
            return true
        }
        if pendingZ {
            pendingZ = false
            return true
        }
        if pendingTextObject {
            pendingTextObject = false
            if char == "\u{1B}" {
                pendingOperator = nil
                return true
            }
            return executeTextObject(char, around: pendingTextObjectAround, in: buffer)
        }
        if let kind = pendingMacroTarget {
            pendingMacroTarget = nil
            if char == "\u{1B}" { return true }
            handleMacroTarget(kind: kind, register: char)
            return true
        }
        if let bracketKind = pendingBracket {
            pendingBracket = nil
            if char == "\u{1B}" { return true }
            switch (bracketKind, char) {
            case (.openBracket, "["): sectionBackward(in: buffer); return true
            case (.closeBracket, "]"): sectionForward(in: buffer); return true
            default: return true
            }
        }

        if char.isNumber {
            let digit = char.wholeNumberValue ?? 0
            if countPrefix > 0 || digit > 0 {
                guard countPrefix <= 99_999 else { return true }
                countPrefix = countPrefix * 10 + digit
                return true
            }
        }

        if pendingG {
            pendingG = false
            return handlePendingG(char, in: buffer)
        }

        switch char {
        case "h":
            moveLeft(consumeCount(), in: buffer)
            return true
        case "j":
            moveDown(consumeCount(), in: buffer)
            return true
        case "k":
            moveUp(consumeCount(), in: buffer)
            return true
        case "l":
            moveRight(consumeCount(), in: buffer)
            return true
        case "w":
            let count = consumeCount()
            let op = pendingOperator
            if let op {
                executeOperatorWithMotion(op, motion: { self.wordForward(count, in: buffer) }, in: buffer)
                recordDot(.operatorWithMotion(op: op, motion: "w", shift: false, count: count))
            } else {
                wordForward(count, in: buffer)
            }
            goalColumn = nil
            return true
        case "b":
            let count = consumeCount()
            if let op = pendingOperator {
                executeOperatorWithMotion(op, motion: { self.wordBackward(count, in: buffer) }, in: buffer)
            } else {
                wordBackward(count, in: buffer)
            }
            goalColumn = nil
            return true
        case "e":
            let count = consumeCount()
            if let op = pendingOperator {
                executeOperatorWithMotion(op, motion: { self.wordEndMotion(count, in: buffer) }, inclusive: true, in: buffer)
            } else {
                wordEndMotion(count, in: buffer)
            }
            goalColumn = nil
            return true
        case "0":
            if let op = pendingOperator {
                executeOperatorWithMotion(op, motion: { self.moveToLineStart(in: buffer) }, in: buffer)
            } else {
                moveToLineStart(in: buffer)
            }
            goalColumn = nil
            return true
        case "$":
            if let op = pendingOperator {
                executeOperatorWithMotion(op, motion: { self.moveToLineEnd(in: buffer) }, inclusive: true, in: buffer)
            } else {
                moveToLineEnd(in: buffer)
            }
            goalColumn = nil
            return true
        case "^", "_":
            if let op = pendingOperator {
                executeOperatorWithMotion(op, motion: {
                    let target = self.firstNonBlankOffset(from: buffer.selectedRange().location, in: buffer)
                    buffer.setSelectedRange(NSRange(location: target, length: 0))
                }, in: buffer)
            } else {
                let target = firstNonBlankOffset(from: buffer.selectedRange().location, in: buffer)
                buffer.setSelectedRange(NSRange(location: target, length: 0))
            }
            goalColumn = nil
            return true
        case "g":
            pendingG = true
            return true
        case "G":
            return handleG(in: buffer)
        case "W":
            let count = consumeCount()
            executeMotion(in: buffer) { self.bigWordForward(count, in: buffer) }
            return true
        case "B":
            let count = consumeCount()
            executeMotion(in: buffer) { self.bigWordBackward(count, in: buffer) }
            return true
        case "E":
            let count = consumeCount()
            executeMotion(in: buffer, inclusive: true) { self.bigWordEndMotion(count, in: buffer) }
            return true

        case "i":
            if pendingOperator != nil {
                pendingTextObject = true
                pendingTextObjectAround = false
                return true
            }
            countPrefix = 0
            setMode(.insert)
            return true
        case "a":
            if pendingOperator != nil {
                pendingTextObject = true
                pendingTextObjectAround = true
                return true
            }
            countPrefix = 0
            let pos = buffer.selectedRange().location
            if pos < buffer.length {
                buffer.setSelectedRange(NSRange(location: pos + 1, length: 0))
            }
            setMode(.insert)
            return true
        case "I":
            countPrefix = 0
            let target = firstNonBlankOffset(from: buffer.selectedRange().location, in: buffer)
            buffer.setSelectedRange(NSRange(location: target, length: 0))
            setMode(.insert)
            return true
        case "A":
            countPrefix = 0
            moveToLineEnd(in: buffer)
            let pos = buffer.selectedRange().location
            let lineRange = buffer.lineRange(forOffset: pos)
            let lineEnd = lineRange.location + lineRange.length
            let targetEnd = lineEnd > lineRange.location && lineEnd <= buffer.length
                && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
            buffer.setSelectedRange(NSRange(location: targetEnd, length: 0))
            setMode(.insert)
            return true
        case "o":
            countPrefix = 0
            let pos = buffer.selectedRange().location
            let lineRange = buffer.lineRange(forOffset: pos)
            let lineEnd = lineRange.location + lineRange.length
            let lineEndsWithNewline = lineEnd > lineRange.location
                && buffer.character(at: lineEnd - 1) == 0x0A
            buffer.replaceCharacters(in: NSRange(location: lineEnd, length: 0), with: "\n")
            let cursorPos = lineEndsWithNewline ? lineEnd : lineEnd + 1
            buffer.setSelectedRange(NSRange(location: cursorPos, length: 0))
            setMode(.insert)
            return true
        case "O":
            countPrefix = 0
            let pos = buffer.selectedRange().location
            let lineRange = buffer.lineRange(forOffset: pos)
            buffer.replaceCharacters(in: NSRange(location: lineRange.location, length: 0), with: "\n")
            buffer.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            setMode(.insert)
            return true

        case "v":
            countPrefix = 0
            let pos = buffer.selectedRange().location
            visualAnchor = pos
            cursorOffset = pos
            let initialLen = pos < buffer.length ? 1 : 0
            buffer.setSelectedRange(NSRange(location: pos, length: initialLen))
            setMode(.visual(linewise: false))
            return true
        case "V":
            countPrefix = 0
            let pos = buffer.selectedRange().location
            let lineRange = buffer.lineRange(forOffset: pos)
            visualAnchor = lineRange.location
            cursorOffset = pos
            buffer.setSelectedRange(lineRange)
            setMode(.visual(linewise: true))
            return true

        case "d":
            if pendingOperator == .delete {
                deleteLine(consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            beginOperator(.delete)
            return true
        case "y":
            if pendingOperator == .yank {
                yankLine(consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            beginOperator(.yank)
            return true
        case "c":
            if pendingOperator == .change {
                changeLine(consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            beginOperator(.change)
            return true

        case "D":
            beginOperator(.delete)
            executeMotion(in: buffer, inclusive: true) { self.moveToLineEnd(in: buffer) }
            return true
        case "Y":
            yankLine(consumeCount(), in: buffer)
            return true
        case "C":
            beginOperator(.change)
            executeMotion(in: buffer, inclusive: true) { self.moveToLineEnd(in: buffer) }
            return true

        case "X":
            deleteCharBeforeCursor(consumeCount(), in: buffer)
            return true

        case "s":
            let count = consumeCount()
            substituteChars(count, in: buffer)
            return true
        case "S":
            changeLine(consumeCount(), in: buffer)
            return true

        case "J":
            joinLines(consumeCount(), withSpace: true, in: buffer)
            return true

        case "f":
            pendingFindChar = VimFindCharRequest(forward: true, till: false)
            return true
        case "F":
            pendingFindChar = VimFindCharRequest(forward: false, till: false)
            return true
        case "t":
            pendingFindChar = VimFindCharRequest(forward: true, till: true)
            return true
        case "T":
            pendingFindChar = VimFindCharRequest(forward: false, till: true)
            return true
        case ";":
            guard let last = lastFindChar else { return true }
            let req = VimFindCharRequest(forward: last.forward, till: last.till)
            _ = executeFindChar(last.char, request: req, in: buffer)
            return true
        case ",":
            guard let last = lastFindChar else { return true }
            let req = VimFindCharRequest(forward: !last.forward, till: last.till)
            _ = executeFindChar(last.char, request: req, in: buffer)
            return true

        case "r":
            pendingReplaceChar = true
            return true
        case "R":
            countPrefix = 0
            operatorCount = 0
            setMode(.replace)
            return true

        case "~":
            if pendingOperator == .toggleCase {
                applyCaseToLine(.toggleCase, count: consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            toggleCaseUnderCursor(consumeCount(), in: buffer)
            return true

        case ">":
            if pendingOperator == .indent {
                indentLine(consumeCount(), outdent: false, in: buffer)
                pendingOperator = nil
                return true
            }
            beginOperator(.indent)
            return true
        case "<":
            if pendingOperator == .outdent {
                indentLine(consumeCount(), outdent: true, in: buffer)
                pendingOperator = nil
                return true
            }
            beginOperator(.outdent)
            return true

        case "?":
            countPrefix = 0
            operatorCount = 0
            setMode(.commandLine(buffer: "?"))
            return true

        case "%":
            jumpToMatchingBracket(in: buffer)
            return true

        case "n":
            let count = consumeCount()
            for _ in 0..<count { searchNext(in: buffer, reverseDirection: false) }
            return true
        case "N":
            let count = consumeCount()
            for _ in 0..<count { searchNext(in: buffer, reverseDirection: true) }
            return true
        case "*":
            searchWordUnderCursor(forward: true, in: buffer)
            return true
        case "#":
            searchWordUnderCursor(forward: false, in: buffer)
            return true

        case "m":
            pendingMarkSet = true
            return true
        case "'":
            pendingMarkJumpExact = false
            return true
        case "`":
            pendingMarkJumpExact = true
            return true
        case "\"":
            pendingRegisterSelect = true
            return true

        case ".":
            let count = consumeCount()
            replayLastDot(count: count, in: buffer)
            return true

        case "(":
            sentenceBackward(consumeCount(), in: buffer)
            return true
        case ")":
            sentenceForward(consumeCount(), in: buffer)
            return true
        case "{":
            paragraphBackward(consumeCount(), in: buffer)
            return true
        case "}":
            paragraphForward(consumeCount(), in: buffer)
            return true
        case "[":
            pendingBracket = .openBracket
            return true
        case "]":
            pendingBracket = .closeBracket
            return true

        case "q":
            if macroRecording != nil {
                macroRecording = nil
            } else {
                pendingMacroTarget = .recordTarget
            }
            return true
        case "@":
            pendingMacroCount = consumeCount()
            pendingMacroTarget = .replayTarget
            return true

        case "H":
            jumpToVisibleLine(.top, in: buffer)
            return true
        case "M":
            jumpToVisibleLine(.middle, in: buffer)
            return true
        case "L":
            jumpToVisibleLine(.bottom, in: buffer)
            return true

        case "z":
            pendingZ = true
            return true

        case "p":
            let count = consumeCount()
            for _ in 0..<count { paste(after: true, in: buffer) }
            return true
        case "P":
            let count = consumeCount()
            for _ in 0..<count { paste(after: false, in: buffer) }
            return true

        case "/":
            countPrefix = 0
            setMode(.commandLine(buffer: "/"))
            return true
        case ":":
            countPrefix = 0
            setMode(.commandLine(buffer: ":"))
            return true

        case "u":
            if pendingOperator == .lowercase {
                applyCaseToLine(.lowercase, count: consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            let count = consumeCount()
            for _ in 0..<count { buffer.undo() }
            return true
        case "U":
            if pendingOperator == .uppercase {
                applyCaseToLine(.uppercase, count: consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            let explicitCount = countPrefix
            countPrefix = 0
            operatorCount = 0
            let undoCount: Int
            if explicitCount > 0 {
                undoCount = explicitCount
            } else if editsOnCurrentLine > 0 {
                undoCount = editsOnCurrentLine
            } else {
                undoCount = 1
            }
            for _ in 0..<undoCount { buffer.undo() }
            editsOnCurrentLine = 0
            return true

        case "x":
            let count = consumeCount()
            deleteCharUnderCursor(count, in: buffer)
            recordDot(.deleteCharForward(count: count))
            return true

        default:
            if char == "\u{1B}" {
                pendingOperator = nil
                countPrefix = 0
                pendingG = false
                return true
            }
            countPrefix = 0
            pendingOperator = nil
            return true
        }
    }

    func handlePendingG(_ char: Character, in buffer: VimTextBuffer) -> Bool {
        switch char {
        case "g":
            let count = countPrefix
            countPrefix = 0
            operatorCount = 0
            if let op = pendingOperator {
                executeLinewiseOperator(op, fromOffset: buffer.selectedRange().location,
                                        toLine: count > 0 ? count - 1 : 0, in: buffer)
                pendingOperator = nil
            } else {
                if count > 1 {
                    goToLine(count - 1, in: buffer)
                } else {
                    let target = firstNonBlankOffset(from: 0, in: buffer)
                    buffer.setSelectedRange(NSRange(location: target, length: 0))
                }
            }
            goalColumn = nil
            return true
        case "e":
            let count = consumeCount()
            executeMotion(in: buffer, inclusive: true) { self.wordEndBackwardMotion(count, in: buffer) }
            return true
        case "E":
            let count = consumeCount()
            executeMotion(in: buffer, inclusive: true) { self.bigWordEndBackwardMotion(count, in: buffer) }
            return true
        case "i":
            countPrefix = 0
            operatorCount = 0
            if let target = lastInsertOffset {
                let clamped = min(max(0, target), buffer.length)
                buffer.setSelectedRange(NSRange(location: clamped, length: 0))
            }
            setMode(.insert)
            return true
        case "v":
            countPrefix = 0
            operatorCount = 0
            reselectLastVisual(in: buffer)
            return true
        case "j":
            let count = consumeCount()
            moveDown(count, in: buffer)
            return true
        case "k":
            let count = consumeCount()
            moveUp(count, in: buffer)
            return true
        case "J":
            joinLines(consumeCount(), withSpace: false, in: buffer)
            return true
        case "u":
            if pendingOperator == .lowercase {
                applyCaseToLine(.lowercase, count: consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            beginOperator(.lowercase)
            return true
        case "U":
            if pendingOperator == .uppercase {
                applyCaseToLine(.uppercase, count: consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            beginOperator(.uppercase)
            return true
        case "~":
            if pendingOperator == .toggleCase {
                applyCaseToLine(.toggleCase, count: consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            beginOperator(.toggleCase)
            return true
        default:
            countPrefix = 0
            operatorCount = 0
            pendingOperator = nil
            return true
        }
    }

    func handleG(in buffer: VimTextBuffer) -> Bool {
        let count = countPrefix
        countPrefix = 0
        let targetLine: Int
        if count > 0 {
            targetLine = min(max(0, count - 1), buffer.lineCount - 1)
        } else {
            targetLine = max(0, buffer.lineCount - 1)
        }
        if let op = pendingOperator {
            executeLinewiseOperator(op, fromOffset: buffer.selectedRange().location,
                                    toLine: targetLine, in: buffer)
            pendingOperator = nil
            operatorCount = 0
        } else {
            let origin = buffer.selectedRange().location
            let lineStart = buffer.offset(forLine: targetLine, column: 0)
            let target = firstNonBlankOffset(from: lineStart, in: buffer)
            buffer.setSelectedRange(NSRange(location: target, length: 0))
            lastJumpOrigin = origin
        }
        goalColumn = nil
        return true
    }

    func beginOperator(_ op: VimOperator) {
        operatorCount = countPrefix
        countPrefix = 0
        pendingOperator = op
    }

    func executeMotion(in buffer: VimTextBuffer, inclusive: Bool = false, _ motion: () -> Void) {
        if let op = pendingOperator {
            executeOperatorWithMotion(op, motion: motion, inclusive: inclusive, in: buffer)
        } else {
            motion()
        }
        goalColumn = nil
    }

    func executeLinewiseOperator(_ op: VimOperator, fromOffset: Int, toLine: Int, in buffer: VimTextBuffer) {
        let startLineRange = buffer.lineRange(forOffset: fromOffset)
        let targetOffset = buffer.offset(forLine: toLine, column: 0)
        let endLineRange = buffer.lineRange(forOffset: targetOffset)
        let rangeStart = min(startLineRange.location, endLineRange.location)
        let rangeEnd = max(
            startLineRange.location + startLineRange.length,
            endLineRange.location + endLineRange.length
        )
        let range = NSRange(location: rangeStart, length: rangeEnd - rangeStart)
        executeOperatorOnRange(op, range: range, linewise: true, in: buffer)
    }
}
