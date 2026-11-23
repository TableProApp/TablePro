//
//  VimEngine+NormalMode.swift
//  TablePro
//

import Foundation

extension VimEngine {
    func processNormal(_ char: Character, shift: Bool) -> Bool {
        guard let buffer else { return false }
        if char == "\u{1B}" {
            cancelPendingCommand()
            return true
        }
        if pendingRegisterSelect {
            pendingRegisterSelect = false
            // `""` names the unnamed register.
            selectedRegister = char == "\"" ? nil : char
            return true
        }
        if isCountKey(char), let digit = char.wholeNumberValue {
            if countPrefix <= 99_999 { countPrefix = countPrefix * 10 + digit }
            return true
        }
        let consumed = processNormalCommand(char, shift: shift, in: buffer)
        // A finished command drops the count and register typed for it, used or not.
        if !hasPendingCommand {
            countPrefix = 0
            operatorCount = 0
            selectedRegister = nil
        }
        return consumed
    }

    private var takesCharacterArgument: Bool {
        pendingFindChar != nil || pendingReplaceChar || pendingMarkSet || pendingMarkJumpExact != nil || pendingZ
            || pendingTextObject || pendingMacroTarget != nil || pendingBracket != nil
    }

    // A digit that adds to the count, not one that names a register, a character or the `0` motion.
    func isCountKey(_ char: Character) -> Bool {
        guard !pendingRegisterSelect, !takesCharacterArgument, char.isASCII, let digit = char.wholeNumberValue else {
            return false
        }
        return countPrefix > 0 || digit > 0
    }

    private func processNormalCommand(_ char: Character, shift: Bool, in buffer: VimTextBuffer) -> Bool { // swiftlint:disable:this function_body_length
        if let req = pendingFindChar {
            pendingFindChar = nil
            return executeFindChar(char, request: req, in: buffer)
        }
        if pendingReplaceChar {
            pendingReplaceChar = false
            return executeReplaceChar(char, in: buffer)
        }
        if pendingMarkSet {
            pendingMarkSet = false
            setMark(char, at: buffer.selectedRange().location, in: buffer)
            return true
        }
        if let exact = pendingMarkJumpExact {
            pendingMarkJumpExact = nil
            jumpToMark(char, exact: exact, in: buffer)
            return true
        }
        if pendingZ {
            pendingZ = false
            return true
        }
        if pendingTextObject {
            pendingTextObject = false
            return executeTextObject(char, around: pendingTextObjectAround, in: buffer)
        }
        if let kind = pendingMacroTarget {
            pendingMacroTarget = nil
            handleMacroTarget(kind: kind, register: char)
            return true
        }
        if let bracketKind = pendingBracket {
            pendingBracket = nil
            let count = consumeCount()
            switch (bracketKind, char) {
            case (.openBracket, "["):
                applyMotion(to: sectionTarget(forward: false, count: count, in: buffer), kind: .exclusive, jump: true, in: buffer)
            case (.closeBracket, "]"):
                applyMotion(to: sectionTarget(forward: true, count: count, in: buffer), kind: .exclusive, jump: true, in: buffer)
            default:
                cancelPendingCommand()
            }
            return true
        }

        if pendingG {
            pendingG = false
            return handlePendingG(char, in: buffer)
        }

        if handleNormalControl(char, in: buffer) {
            return true
        }

        // A key that is not a motion, a text object or the operator doubled ends the command, as Vim's operators
        // accept nothing else.
        if let op = pendingOperator, !acceptsAfterOperator(char, op) {
            cancelPendingCommand()
            return true
        }

        switch char {
        case "h":
            let count = consumeCount()
            executeMotion(in: buffer) { self.moveLeft(count, in: buffer) }
            return true
        case "j":
            moveDown(consumeCount(), in: buffer)
            return true
        case "k":
            moveUp(consumeCount(), in: buffer)
            return true
        case "l":
            let count = consumeCount()
            executeMotion(in: buffer) { self.moveRight(count, in: buffer) }
            return true
        case "w":
            wordMotion(consumeCount(), bigWord: false, in: buffer)
            return true
        case "b" where buffer.selectedRange().location == 0, "B" where buffer.selectedRange().location == 0:
            // Nothing before the start of the text, so the motion fails and an operator does nothing.
            applyMotion(to: nil, kind: .exclusive, in: buffer)
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
            wordMotion(consumeCount(), bigWord: true, in: buffer)
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
            // On an empty line the caret is on the line break, and the text goes before it.
            if pos < contentEnd(ofLineAt: pos, in: buffer) {
                buffer.setSelectedRange(NSRange(location: characterEnd(at: pos, in: buffer), length: 0))
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
            replace(NSRange(location: lineEnd, length: 0), with: "\n", in: buffer)
            let cursorPos = lineEndsWithNewline ? lineEnd : lineEnd + 1
            buffer.setSelectedRange(NSRange(location: cursorPos, length: 0))
            setMode(.insert)
            return true
        case "O":
            countPrefix = 0
            let pos = buffer.selectedRange().location
            let lineRange = buffer.lineRange(forOffset: pos)
            replace(NSRange(location: lineRange.location, length: 0), with: "\n", in: buffer)
            buffer.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            setMode(.insert)
            return true

        case "v":
            countPrefix = 0
            let pos = buffer.selectedRange().location
            visualAnchor = pos
            cursorOffset = pos
            buffer.setSelectedRange(buffer.characterRange(at: pos))
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
            guard let last = lastFindChar else {
                applyMotion(to: nil, kind: .exclusive, in: buffer)
                return true
            }
            let req = VimFindCharRequest(forward: last.forward, till: last.till)
            _ = executeFindChar(last.char, request: req, in: buffer)
            return true
        case ",":
            guard let last = lastFindChar else {
                applyMotion(to: nil, kind: .exclusive, in: buffer)
                return true
            }
            let req = VimFindCharRequest(forward: !last.forward, till: last.till)
            _ = executeFindChar(last.char, request: req, in: buffer)
            return true

        case "r":
            pendingReplaceChar = true
            return true
        case "R":
            countPrefix = 0
            operatorCount = 0
            replaceModeEdits.removeAll()
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

        case "?", "/", ":":
            // A count before a search finds that many matches, as `2d/x` deletes up to the second x.
            searchCount = char == ":" ? 1 : consumeCount()
            countPrefix = 0
            operatorCount = 0
            setMode(.commandLine(buffer: String(char)))
            return true

        case "%":
            if countPrefix > 0 || operatorCount > 0 {
                applyMotion(to: percentLineTarget(consumeCount(), in: buffer), kind: .linewise, jump: true, in: buffer)
            } else {
                applyMotion(to: matchingBracketTarget(in: buffer), kind: .inclusive, jump: true, in: buffer)
            }
            return true

        case "\r", "+":
            applyMotion(to: lineStepTarget(consumeCount(), in: buffer), kind: .linewise, in: buffer)
            return true
        case "-":
            applyMotion(to: lineStepTarget(-consumeCount(), in: buffer), kind: .linewise, in: buffer)
            return true

        case "n", "N":
            let target = searchNextTarget(count: consumeCount(), reverseDirection: char == "N", in: buffer)
            applyMotion(to: target, kind: .exclusive, jump: true, in: buffer)
            return true
        case "*", "#":
            let target = searchWordUnderCursorTarget(forward: char == "*", count: consumeCount(), in: buffer)
            applyMotion(to: target, kind: .exclusive, jump: true, in: buffer)
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
            repeatLastChange(count: countPrefix > 0 ? consumeCount() : nil)
            return true

        case "(", ")":
            let target = sentenceTarget(forward: char == ")", count: consumeCount(), in: buffer)
            applyMotion(to: target, kind: .exclusive, jump: true, in: buffer)
            return true
        case "{", "}":
            let target = paragraphTarget(forward: char == "}", count: consumeCount(), in: buffer)
            applyMotion(to: target, kind: .exclusive, jump: true, in: buffer)
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

        case "H", "M", "L":
            let position: VimScreenPosition = char == "H" ? .top : char == "M" ? .middle : .bottom
            let target = visibleLineTarget(position, count: consumeCount(), in: buffer)
            applyMotion(to: target, kind: .linewise, jump: true, in: buffer)
            return true

        case "z":
            pendingZ = true
            return true

        case "p", "P":
            paste(after: char == "p", count: consumeCount(), in: buffer)
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
            deleteCharUnderCursor(consumeCount(), in: buffer)
            return true

        default:
            cancelPendingCommand()
            return true
        }
    }

    private static let keysAfterOperator: Set<Character> = [
        "h", "j", "k", "l", "w", "b", "e", "W", "B", "E", "0", "$", "^", "_", "g", "G", "f", "F", "t", "T", ";", ",",
        "%", "n", "N", "*", "#", "'", "`", "(", ")", "{", "}", "[", "]", "H", "M", "L", "/", "?", ":", "\r", "+", "-",
        "i", "a"
    ]

    private func acceptsAfterOperator(_ char: Character, _ op: VimOperator) -> Bool {
        if Self.keysAfterOperator.contains(char) { return true }
        switch char {
        case "d": return op == .delete
        case "y": return op == .yank
        case "c": return op == .change
        case ">": return op == .indent
        case "<": return op == .outdent
        case "~": return op == .toggleCase
        case "u": return op == .lowercase
        case "U": return op == .uppercase
        default: return false
        }
    }

    func handlePendingG(_ char: Character, in buffer: VimTextBuffer) -> Bool {
        if pendingOperator != nil, char == "i" || char == "v" || char == "J" {
            cancelPendingCommand()
            return true
        }
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
        case "t", "T":
            let count = countPrefix
            countPrefix = 0
            operatorCount = 0
            guard pendingOperator == nil else {
                pendingOperator = nil
                return true
            }
            if char == "t" {
                onCommand?(count > 0 ? "tabnext \(count)" : "tabnext")
            } else {
                onCommand?("tabprevious \(max(count, 1))")
            }
            return true
        case "u":
            if pendingOperator == .lowercase {
                applyCaseToLine(.lowercase, count: consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            if pendingOperator != nil {
                cancelPendingCommand()
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
            if pendingOperator != nil {
                cancelPendingCommand()
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
            if pendingOperator != nil {
                cancelPendingCommand()
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

    // Moves to `target`, or with an operator pending applies it from the cursor to `target`. A motion that found no
    // target ends the command, as Vim's failed motions do.
    func applyMotion(to target: Int?, kind: VimMotionKind, jump: Bool = false, in buffer: VimTextBuffer) {
        goalColumn = nil
        guard let target else {
            cancelPendingCommand()
            return
        }
        let origin = buffer.selectedRange().location
        if let op = pendingOperator {
            operate(op, from: origin, to: target, kind: kind, in: buffer)
            return
        }
        let destination = kind == .linewise ? target : clampToContentPosition(target, in: buffer)
        buffer.setSelectedRange(NSRange(location: destination, length: 0))
        if jump { lastJumpOrigin = origin }
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
