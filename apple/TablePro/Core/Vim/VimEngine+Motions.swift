//
//  VimEngine+Motions.swift
//  TablePro
//

import Foundation

extension VimEngine {
    func moveLeft(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let newPos = characterOffset(before: pos, count: count, limit: lineRange.location, in: buffer)
        buffer.setSelectedRange(NSRange(location: newPos, length: 0))
        goalColumn = nil
    }

    func moveRight(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd: Int
        if lineEnd > lineRange.location && lineEnd <= buffer.length && buffer.character(at: lineEnd - 1) == 0x0A {
            contentEnd = lineEnd - 1
        } else {
            contentEnd = lineEnd
        }
        // With an operator pending, `l` reaches past the last character, so `dl` there deletes it.
        let maxPos = pendingOperator != nil || contentEnd == lineRange.location
            ? contentEnd
            : characterStart(at: contentEnd - 1, in: buffer)
        let newPos = characterOffset(after: pos, count: count, limit: maxPos, in: buffer)
        buffer.setSelectedRange(NSRange(location: newPos, length: 0))
        goalColumn = nil
    }

    func moveDown(_ count: Int, in buffer: VimTextBuffer) {
        moveVertically(by: count, in: buffer)
    }

    func moveUp(_ count: Int, in buffer: VimTextBuffer) {
        moveVertically(by: -count, in: buffer)
    }

    // An operator takes the lines whole; on the first or last line it has nothing to take and the command ends.
    private func moveVertically(by delta: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let (line, col) = buffer.lineAndColumn(forOffset: pos)
        if goalColumn == nil { goalColumn = col }
        let targetLine = min(max(0, line + delta), buffer.lineCount - 1)
        let newPos = buffer.offset(forLine: targetLine, column: goalColumn ?? col)
        guard let op = pendingOperator else {
            buffer.setSelectedRange(NSRange(location: newPos, length: 0))
            return
        }
        guard targetLine != line else {
            cancelPendingCommand()
            return
        }
        operate(op, from: pos, to: newPos, kind: .linewise, in: buffer)
    }

    func moveToLineStart(in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        buffer.setSelectedRange(NSRange(location: lineRange.location, length: 0))
    }

    func moveToLineEnd(in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd: Int
        if lineEnd > lineRange.location && lineEnd <= buffer.length && buffer.character(at: lineEnd - 1) == 0x0A {
            contentEnd = lineEnd - 1
        } else {
            contentEnd = lineEnd
        }
        let finalPos = contentEnd > lineRange.location ? characterStart(at: contentEnd - 1, in: buffer) : lineRange.location
        buffer.setSelectedRange(NSRange(location: finalPos, length: 0))
    }

    func firstNonBlankOffset(from position: Int, in buffer: VimTextBuffer) -> Int {
        let lineRange = buffer.lineRange(forOffset: position)
        var target = lineRange.location
        let lineEnd = lineRange.location + lineRange.length
        while target < lineEnd {
            let ch = buffer.character(at: target)
            if ch != 0x20 && ch != 0x09 && ch != 0x0A { break }
            target += 1
        }
        if target >= lineEnd || buffer.character(at: target) == 0x0A {
            target = lineRange.location
        }
        return target
    }

    func goToLine(_ line: Int, in buffer: VimTextBuffer) {
        let targetLine = min(max(0, line), buffer.lineCount - 1)
        let offset = buffer.offset(forLine: targetLine, column: 0)
        buffer.setSelectedRange(NSRange(location: offset, length: 0))
    }

    // `cw` on a word changes to its end, as `ce` does; elsewhere `w` and `W` go to the next word's start.
    func wordMotion(_ count: Int, bigWord: Bool, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        if pendingOperator == .change, pos < buffer.length, !isBlank(buffer.character(at: pos)) {
            let end: (Int) -> Int = { bigWord ? buffer.bigWordEnd(from: $0) : buffer.wordEnd(from: $0) }
            var target = end(pos - 1)
            for _ in 1..<max(1, count) { target = end(target) }
            applyMotion(to: target, kind: .inclusive, in: buffer)
            return
        }
        applyMotion(to: wordForwardTarget(count, bigWord: bigWord, in: buffer), kind: .exclusive, in: buffer)
    }

    // After an operator the last word stops at the end of its line, and from an empty line at the next line's
    // start, which `:help exclusive` turns into the empty line.
    func wordForwardTarget(_ count: Int, bigWord: Bool, in buffer: VimTextBuffer) -> Int? {
        var pos = buffer.selectedRange().location
        let isOperator = pendingOperator != nil
        for i in 0..<count {
            let next = bigWord
                ? buffer.bigWordBoundary(forward: true, from: pos)
                : buffer.wordBoundary(forward: true, from: pos)
            if isOperator && i == count - 1 {
                let line = buffer.lineRange(forOffset: pos)
                if buffer.lineRange(forOffset: min(next, buffer.length)).location != line.location {
                    let end = contentEnd(ofLineAt: pos, in: buffer)
                    if end > line.location { return end }
                    return NSMaxRange(line) < buffer.length ? NSMaxRange(line) : nil
                }
            }
            pos = next
        }
        return pos
    }

    func contentEnd(ofLineAt offset: Int, in buffer: VimTextBuffer) -> Int {
        let lineRange = buffer.lineRange(forOffset: offset)
        let lineEnd = NSMaxRange(lineRange)
        let endsInNewline = lineEnd > lineRange.location && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A
        return endsInNewline ? lineEnd - 1 : lineEnd
    }

    func isBlank(_ ch: unichar) -> Bool {
        ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D
    }

    func clampToContentPosition(_ offset: Int, in buffer: VimTextBuffer) -> Int {
        guard buffer.length > 0 else { return 0 }
        var pos = min(max(0, offset), buffer.length - 1)
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let endsInNewline = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A
        let contentEnd = endsInNewline ? lineEnd - 1 : lineEnd
        if pos >= contentEnd && contentEnd > lineRange.location {
            pos = contentEnd - 1
        }
        return characterStart(at: pos, in: buffer)
    }

    func wordBackward(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count {
            pos = buffer.wordBoundary(forward: false, from: pos)
        }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    func wordEndMotion(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count {
            pos = buffer.wordEnd(from: pos)
        }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    func bigWordBackward(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count { pos = buffer.bigWordBoundary(forward: false, from: pos) }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    func bigWordEndMotion(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count { pos = buffer.bigWordEnd(from: pos) }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    func wordEndBackwardMotion(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count { pos = buffer.wordEndBackward(from: pos) }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    func bigWordEndBackwardMotion(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count { pos = buffer.bigWordEndBackward(from: pos) }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    // The first bracket at or after the cursor on its line, and the bracket that pairs with it.
    func matchingBracketTarget(in buffer: VimTextBuffer) -> Int? {
        let pos = buffer.selectedRange().location
        let lineEnd = contentEnd(ofLineAt: pos, in: buffer)
        var scan = pos
        while scan < lineEnd {
            if let target = buffer.matchingBracket(at: scan) { return target }
            scan += 1
        }
        return nil
    }

    // `{count}%`: the line that far through the text, as Vim rounds it.
    func percentLineTarget(_ count: Int, in buffer: VimTextBuffer) -> Int? {
        guard count <= 100 else { return nil }
        let line = min(max(0, (count * buffer.lineCount + 99) / 100 - 1), buffer.lineCount - 1)
        return firstNonBlankOffset(from: buffer.offset(forLine: line, column: 0), in: buffer)
    }

    // Enter and `+` go down `delta` lines, `-` up, to the first non-blank; at the first or last line they fail.
    func lineStepTarget(_ delta: Int, in buffer: VimTextBuffer) -> Int? {
        let line = buffer.lineAndColumn(forOffset: buffer.selectedRange().location).line
        let target = min(max(0, line + delta), buffer.lineCount - 1)
        guard target != line else { return nil }
        return firstNonBlankOffset(from: buffer.offset(forLine: target, column: 0), in: buffer)
    }

    // A count is lines from the top for H and from the bottom for L.
    func visibleLineTarget(_ position: VimScreenPosition, count: Int, in buffer: VimTextBuffer) -> Int {
        let (firstLine, lastLine) = buffer.visibleLineRange()
        let skip = max(0, count - 1)
        let targetLine: Int
        switch position {
        case .top: targetLine = min(firstLine + skip, lastLine)
        case .bottom: targetLine = max(lastLine - skip, firstLine)
        case .middle: targetLine = (firstLine + lastLine) / 2
        }
        let lineStart = buffer.offset(forLine: targetLine, column: 0)
        return firstNonBlankOffset(from: lineStart, in: buffer)
    }

    func executeFindChar(_ char: Character, request: VimFindCharRequest, in buffer: VimTextBuffer) -> Bool {
        lastFindChar = VimLastFindChar(char: char, forward: request.forward, till: request.till)
        let target = String(char)
        let count = consumeCount()
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        let matches: (NSRange) -> Bool = { buffer.string(in: $0) == target }
        // An offset below the line start ends the backward scan.
        let previous: (Int) -> Int = { offset in
            offset > lineRange.location ? self.characterStart(at: offset - 1, in: buffer) : offset - 1
        }

        var resolved: Int?
        if request.forward {
            var scanStart = characterEnd(at: pos, in: buffer)
            if request.till { scanStart = characterEnd(at: scanStart, in: buffer) }
            scanStart = min(scanStart, contentEnd)
            for _ in 0..<count {
                resolved = nil
                var idx = scanStart
                while idx < contentEnd {
                    let range = buffer.characterRange(at: idx)
                    if matches(range) {
                        resolved = idx
                        scanStart = NSMaxRange(range)
                        break
                    }
                    idx = NSMaxRange(range)
                }
                if resolved == nil { break }
            }
        } else {
            var scanStart = previous(pos)
            if request.till { scanStart = previous(scanStart) }
            for _ in 0..<count {
                resolved = nil
                var idx = scanStart
                while idx >= lineRange.location {
                    if matches(buffer.characterRange(at: idx)) {
                        resolved = idx
                        scanStart = previous(idx)
                        break
                    }
                    idx = previous(idx)
                }
                if resolved == nil { break }
            }
        }

        guard var finalPos = resolved else {
            cancelPendingCommand()
            return true
        }
        if request.till {
            finalPos = request.forward ? previous(finalPos) : characterEnd(at: finalPos, in: buffer)
        }
        // `f` and `t` take the character they reach; `F` and `T` stop short of the cursor's.
        executeMotion(in: buffer, inclusive: request.forward) {
            buffer.setSelectedRange(NSRange(location: finalPos, length: 0))
        }
        return true
    }

    func sentenceTarget(forward: Bool, count: Int, in buffer: VimTextBuffer) -> Int {
        var pos = buffer.selectedRange().location
        for _ in 0..<count {
            pos = forward ? nextSentenceStart(after: pos, in: buffer) : previousSentenceStart(before: pos, in: buffer)
        }
        return pos
    }

    func nextSentenceStart(after origin: Int, in buffer: VimTextBuffer) -> Int {
        var i = origin
        while i < buffer.length - 1 {
            let ch = buffer.character(at: i)
            let nextCh = buffer.character(at: i + 1)
            let endsSentence = ch == 0x2E || ch == 0x21 || ch == 0x3F
            let followedByBoundary = nextCh == 0x20 || nextCh == 0x09 || nextCh == 0x0A
            if endsSentence && followedByBoundary {
                var j = i + 1
                while j < buffer.length {
                    let cj = buffer.character(at: j)
                    if cj == 0x20 || cj == 0x09 || cj == 0x0A { j += 1 } else { break }
                }
                if j < buffer.length { return j }
            }
            i += 1
        }
        return buffer.length > 0 ? buffer.length - 1 : 0
    }

    func previousSentenceStart(before origin: Int, in buffer: VimTextBuffer) -> Int {
        var i = origin - 2
        while i >= 0 {
            let ch = buffer.character(at: i)
            if i + 1 < buffer.length {
                let nextCh = buffer.character(at: i + 1)
                let endsSentence = ch == 0x2E || ch == 0x21 || ch == 0x3F
                let followedByBoundary = nextCh == 0x20 || nextCh == 0x09 || nextCh == 0x0A
                if endsSentence && followedByBoundary {
                    var j = i + 1
                    while j < buffer.length {
                        let cj = buffer.character(at: j)
                        if cj == 0x20 || cj == 0x09 || cj == 0x0A { j += 1 } else { break }
                    }
                    if j < origin { return j }
                }
            }
            i -= 1
        }
        return 0
    }

    func paragraphTarget(forward: Bool, count: Int, in buffer: VimTextBuffer) -> Int {
        var pos = buffer.selectedRange().location
        for _ in 0..<count {
            pos = forward ? nextParagraphBoundary(after: pos, in: buffer) : previousParagraphBoundary(before: pos, in: buffer)
        }
        return pos
    }

    func nextParagraphBoundary(after origin: Int, in buffer: VimTextBuffer) -> Int {
        let (originLine, _) = buffer.lineAndColumn(forOffset: origin)
        var line = originLine + 1
        let lineCount = buffer.lineCount
        while line < lineCount {
            if lineIsBlank(line, in: buffer) {
                return buffer.offset(forLine: line, column: 0)
            }
            line += 1
        }
        return lastLineContentEnd(in: buffer)
    }

    // Past the last character, so an operator takes it, and a plain motion steps back onto it.
    func lastLineContentEnd(in buffer: VimTextBuffer) -> Int {
        contentEnd(ofLineAt: buffer.offset(forLine: buffer.lineCount - 1, column: 0), in: buffer)
    }

    func previousParagraphBoundary(before origin: Int, in buffer: VimTextBuffer) -> Int {
        let (originLine, _) = buffer.lineAndColumn(forOffset: origin)
        var line = originLine - 1
        while line > 0 {
            if lineIsBlank(line, in: buffer) {
                return buffer.offset(forLine: line, column: 0)
            }
            line -= 1
        }
        return 0
    }

    // `]]` and `[[`: the next or previous line that starts with `{`. With none, the first or last line, and after an
    // operator the end of the last line.
    func sectionTarget(forward: Bool, count: Int, in buffer: VimTextBuffer) -> Int {
        var line = buffer.lineAndColumn(forOffset: buffer.selectedRange().location).line
        for _ in 0..<count {
            var next = line + (forward ? 1 : -1)
            while next >= 0 && next < buffer.lineCount {
                let off = buffer.offset(forLine: next, column: 0)
                if off < buffer.length && buffer.character(at: off) == 0x7B { break }
                next += forward ? 1 : -1
            }
            guard next >= 0 && next < buffer.lineCount else {
                guard forward else { return 0 }
                let lastLineStart = buffer.offset(forLine: buffer.lineCount - 1, column: 0)
                return pendingOperator != nil ? lastLineContentEnd(in: buffer) : lastLineStart
            }
            line = next
        }
        return buffer.offset(forLine: line, column: 0)
    }

    func lineIsBlank(_ line: Int, in buffer: VimTextBuffer) -> Bool {
        let offset = buffer.offset(forLine: line, column: 0)
        let lineRange = buffer.lineRange(forOffset: offset)
        let lineEnd = lineRange.location + lineRange.length
        if lineEnd <= lineRange.location { return true }
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        return contentEnd == lineRange.location
    }
}
