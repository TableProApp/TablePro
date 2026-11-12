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
        let pos = buffer.selectedRange().location
        let (line, col) = buffer.lineAndColumn(forOffset: pos)
        if goalColumn == nil { goalColumn = col }
        let targetLine = min(buffer.lineCount - 1, line + count)
        let newPos = buffer.offset(forLine: targetLine, column: goalColumn ?? col)
        if let op = pendingOperator {
            let startLineRange = buffer.lineRange(forOffset: pos)
            let endLineRange = buffer.lineRange(forOffset: newPos)
            let rangeStart = min(startLineRange.location, endLineRange.location)
            let rangeEnd = max(
                startLineRange.location + startLineRange.length,
                endLineRange.location + endLineRange.length
            )
            let opRange = NSRange(location: rangeStart, length: rangeEnd - rangeStart)
            executeOperatorOnRange(op, range: opRange, linewise: true, in: buffer)
            pendingOperator = nil
        } else {
            buffer.setSelectedRange(NSRange(location: newPos, length: 0))
        }
    }

    func moveUp(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let (line, col) = buffer.lineAndColumn(forOffset: pos)
        if goalColumn == nil { goalColumn = col }
        let targetLine = max(0, line - count)
        let newPos = buffer.offset(forLine: targetLine, column: goalColumn ?? col)
        if let op = pendingOperator {
            let startLineRange = buffer.lineRange(forOffset: newPos)
            let endLineRange = buffer.lineRange(forOffset: pos)
            let rangeStart = min(startLineRange.location, endLineRange.location)
            let rangeEnd = max(
                startLineRange.location + startLineRange.length,
                endLineRange.location + endLineRange.length
            )
            let opRange = NSRange(location: rangeStart, length: rangeEnd - rangeStart)
            executeOperatorOnRange(op, range: opRange, linewise: true, in: buffer)
            pendingOperator = nil
        } else {
            buffer.setSelectedRange(NSRange(location: newPos, length: 0))
        }
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

    func wordForward(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        let isOperator = pendingOperator != nil
        for i in 0..<count {
            let prev = pos
            let next = buffer.wordBoundary(forward: true, from: pos)
            if isOperator && i == count - 1 {
                let prevLineRange = buffer.lineRange(forOffset: prev)
                let nextLineRange = buffer.lineRange(forOffset: min(next, buffer.length))
                if prevLineRange.location != nextLineRange.location {
                    let lineEnd = prevLineRange.location + prevLineRange.length
                    let contentEnd = lineEnd > prevLineRange.location
                        && lineEnd <= buffer.length
                        && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
                    pos = contentEnd
                    break
                }
            }
            pos = next
        }
        if !isOperator { pos = clampToContentPosition(pos, in: buffer) }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
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

    func bigWordForward(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        let isOperator = pendingOperator != nil
        for _ in 0..<count { pos = buffer.bigWordBoundary(forward: true, from: pos) }
        if !isOperator { pos = clampToContentPosition(pos, in: buffer) }
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

    func jumpToMatchingBracket(in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        var scan = pos
        while scan < contentEnd {
            if let target = buffer.matchingBracket(at: scan) {
                buffer.setSelectedRange(NSRange(location: target, length: 0))
                return
            }
            scan += 1
        }
    }

    func jumpToVisibleLine(_ position: VimScreenPosition, in buffer: VimTextBuffer) {
        let (firstLine, lastLine) = buffer.visibleLineRange()
        let targetLine: Int
        switch position {
        case .top: targetLine = firstLine
        case .bottom: targetLine = lastLine
        case .middle: targetLine = (firstLine + lastLine) / 2
        }
        let lineStart = buffer.offset(forLine: targetLine, column: 0)
        let target = firstNonBlankOffset(from: lineStart, in: buffer)
        buffer.setSelectedRange(NSRange(location: target, length: 0))
        goalColumn = nil
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

        guard var finalPos = resolved else { return true }
        if request.till {
            finalPos = request.forward ? previous(finalPos) : characterEnd(at: finalPos, in: buffer)
        }
        executeMotion(in: buffer, inclusive: true) {
            buffer.setSelectedRange(NSRange(location: finalPos, length: 0))
        }
        return true
    }

    func sentenceForward(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count {
            pos = nextSentenceStart(after: pos, in: buffer)
        }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    func sentenceBackward(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count {
            pos = previousSentenceStart(before: pos, in: buffer)
        }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
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

    func paragraphForward(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count {
            pos = nextParagraphBoundary(after: pos, in: buffer)
        }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    func paragraphBackward(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count {
            pos = previousParagraphBoundary(before: pos, in: buffer)
        }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
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
        return buffer.length > 0 ? buffer.length - 1 : 0
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

    func sectionForward(in buffer: VimTextBuffer) {
        let origin = buffer.selectedRange().location
        let (originLine, _) = buffer.lineAndColumn(forOffset: origin)
        var line = originLine + 1
        while line < buffer.lineCount {
            let off = buffer.offset(forLine: line, column: 0)
            if off < buffer.length && buffer.character(at: off) == 0x7B {
                buffer.setSelectedRange(NSRange(location: off, length: 0))
                return
            }
            line += 1
        }
        buffer.setSelectedRange(NSRange(location: max(0, buffer.length - 1), length: 0))
    }

    func sectionBackward(in buffer: VimTextBuffer) {
        let origin = buffer.selectedRange().location
        let (originLine, _) = buffer.lineAndColumn(forOffset: origin)
        var line = originLine - 1
        while line >= 0 {
            let off = buffer.offset(forLine: line, column: 0)
            if off < buffer.length && buffer.character(at: off) == 0x7B {
                buffer.setSelectedRange(NSRange(location: off, length: 0))
                return
            }
            line -= 1
        }
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
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
