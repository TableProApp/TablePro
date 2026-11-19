//
//  VimEngine+TextObjects.swift
//  TablePro
//

import Foundation

extension VimEngine {
    func executeTextObject(_ key: Character, around: Bool, in buffer: VimTextBuffer) -> Bool {
        let pos = buffer.selectedRange().location
        guard let range = textObjectRange(key: key, around: around, cursor: pos, in: buffer) else {
            pendingOperator = nil
            return true
        }
        // A paragraph is whole lines.
        let linewise = key == "p"
        if mode.isVisual {
            // The object's start becomes Visual's anchor and its end the cursor, so the next motion extends it.
            guard range.length > 0 else { return true }
            var visualLinewise = linewise
            if case .visual(let lw) = mode { visualLinewise = visualLinewise || lw }
            if visualLinewise != mode.isVisualLinewise { setMode(.visual(linewise: visualLinewise)) }
            visualAnchor = range.location
            updateVisualSelection(cursorPos: NSMaxRange(range) - 1, linewise: visualLinewise, in: buffer)
            return true
        }
        if let op = pendingOperator {
            executeOperatorOnRange(op, range: range, linewise: linewise, in: buffer)
            pendingOperator = nil
        }
        return true
    }

    func textObjectRange(key: Character, around: Bool, cursor: Int, in buffer: VimTextBuffer) -> NSRange? {
        switch key {
        case "w": return wordObject(at: cursor, bigWord: false, around: around, in: buffer)
        case "W": return wordObject(at: cursor, bigWord: true, around: around, in: buffer)
        case "\"", "'", "`":
            return quotedObject(at: cursor, delimiter: key, around: around, in: buffer)
        case "(", ")", "b": return bracketedObject(at: cursor, open: "(", close: ")", around: around, in: buffer)
        case "{", "}", "B": return bracketedObject(at: cursor, open: "{", close: "}", around: around, in: buffer)
        case "[", "]": return bracketedObject(at: cursor, open: "[", close: "]", around: around, in: buffer)
        case "<", ">": return bracketedObject(at: cursor, open: "<", close: ">", around: around, in: buffer)
        case "t": return tagObject(at: cursor, around: around, in: buffer)
        case "p": return paragraphObject(at: cursor, around: around, in: buffer)
        default: return nil
        }
    }

    func wordObject(at cursor: Int, bigWord: Bool, around: Bool, in buffer: VimTextBuffer) -> NSRange? {
        guard buffer.length > 0 else { return nil }
        let pos = characterStart(at: min(max(0, cursor), buffer.length - 1), in: buffer)
        let classOf: (Int) -> VimWordScanner.CharacterClass = { offset in
            let cls = self.wordClass(at: offset, in: buffer)
            return bigWord && cls != .whitespace ? .word : cls
        }
        let startClass = classOf(pos)
        var start = pos
        while start > 0 {
            let previous = characterStart(at: start - 1, in: buffer)
            guard classOf(previous) == startClass else { break }
            start = previous
        }
        var rangeEnd = characterEnd(at: pos, in: buffer)
        while rangeEnd < buffer.length && classOf(rangeEnd) == startClass {
            rangeEnd = characterEnd(at: rangeEnd, in: buffer)
        }
        if around {
            var trail = rangeEnd
            while trail < buffer.length {
                let ch = buffer.character(at: trail)
                if ch == 0x20 || ch == 0x09 { trail += 1 } else { break }
            }
            if trail > rangeEnd {
                rangeEnd = trail
            } else {
                while start > 0 {
                    let ch = buffer.character(at: start - 1)
                    if ch == 0x20 || ch == 0x09 { start -= 1 } else { break }
                }
            }
        }
        return NSRange(location: start, length: rangeEnd - start)
    }

    func quotedObject(at cursor: Int, delimiter: Character, around: Bool, in buffer: VimTextBuffer) -> NSRange? {
        guard let scalar = delimiter.unicodeScalars.first else { return nil }
        let quote = unichar(scalar.value)
        let lineRange = buffer.lineRange(forOffset: cursor)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        var open: Int?
        var close: Int?
        var scan = lineRange.location
        while scan < contentEnd {
            if buffer.character(at: scan) == quote {
                if let o = open {
                    if cursor >= o && cursor <= scan {
                        close = scan
                        break
                    }
                    open = scan
                } else {
                    open = scan
                }
            }
            scan += 1
        }
        if close == nil, let o = open, cursor >= o {
            scan = o + 1
            while scan < contentEnd {
                if buffer.character(at: scan) == quote {
                    close = scan
                    break
                }
                scan += 1
            }
        }
        guard let o = open, let c = close, c > o else { return nil }
        if around {
            var rangeEnd = c + 1
            var rangeStart = o
            while rangeEnd < contentEnd {
                let ch = buffer.character(at: rangeEnd)
                if ch == 0x20 || ch == 0x09 { rangeEnd += 1 } else { break }
            }
            if rangeEnd == c + 1 {
                while rangeStart > lineRange.location {
                    let ch = buffer.character(at: rangeStart - 1)
                    if ch == 0x20 || ch == 0x09 { rangeStart -= 1 } else { break }
                }
            }
            return NSRange(location: rangeStart, length: rangeEnd - rangeStart)
        }
        return NSRange(location: o + 1, length: c - o - 1)
    }

    func bracketedObject(
        at cursor: Int,
        open: Character,
        close: Character,
        around: Bool,
        in buffer: VimTextBuffer
    ) -> NSRange? {
        guard let openScalar = open.unicodeScalars.first,
              let closeScalar = close.unicodeScalars.first else { return nil }
        let openCh = unichar(openScalar.value)
        let closeCh = unichar(closeScalar.value)
        var openPos: Int?
        var depth = 0
        if cursor < buffer.length && buffer.character(at: cursor) == openCh {
            openPos = cursor
        } else if cursor < buffer.length && buffer.character(at: cursor) == closeCh {
            var d = 1
            var i = cursor - 1
            while i >= 0 {
                let ch = buffer.character(at: i)
                if ch == closeCh {
                    d += 1
                } else if ch == openCh {
                    d -= 1
                    if d == 0 { openPos = i; break }
                }
                i -= 1
            }
        } else {
            var i = cursor - 1
            depth = 0
            while i >= 0 {
                let ch = buffer.character(at: i)
                if ch == closeCh {
                    depth += 1
                } else if ch == openCh {
                    if depth == 0 { openPos = i; break }
                    depth -= 1
                }
                i -= 1
            }
        }
        guard let o = openPos else { return nil }
        var closePos: Int?
        var d = 1
        var i = o + 1
        while i < buffer.length {
            let ch = buffer.character(at: i)
            if ch == openCh {
                d += 1
            } else if ch == closeCh {
                d -= 1
                if d == 0 { closePos = i; break }
            }
            i += 1
        }
        guard let c = closePos else { return nil }
        if around { return NSRange(location: o, length: c - o + 1) }
        guard c > o + 1 else { return NSRange(location: o + 1, length: 0) }
        return NSRange(location: o + 1, length: c - o - 1)
    }

    func tagObject(at cursor: Int, around: Bool, in buffer: VimTextBuffer) -> NSRange? {
        var openStart: Int?
        var openEnd: Int?
        var i = cursor
        while i >= 0 {
            if buffer.character(at: i) == 0x3C {
                openStart = i
                var j = i + 1
                while j < buffer.length && buffer.character(at: j) != 0x3E { j += 1 }
                if j < buffer.length {
                    openEnd = j
                }
                break
            }
            i -= 1
        }
        guard let os = openStart, let oe = openEnd else { return nil }
        let tagNameStart = os + 1
        let tagName = buffer.string(in: NSRange(location: tagNameStart, length: oe - tagNameStart))
        guard !tagName.hasPrefix("/") else { return nil }
        let closeMarker = "</" + tagName + ">"
        let after = buffer.string(in: NSRange(location: oe + 1, length: buffer.length - oe - 1)) as NSString
        let foundRange = after.range(of: closeMarker)
        guard foundRange.location != NSNotFound else { return nil }
        let closeStart = oe + 1 + foundRange.location
        let closeEnd = closeStart + foundRange.length
        if around { return NSRange(location: os, length: closeEnd - os) }
        return NSRange(location: oe + 1, length: closeStart - oe - 1)
    }

    // Whole lines: the run of paragraph or blank lines at the cursor. `ap` adds the blank lines after a paragraph,
    // or the paragraph after blank lines, and with nothing after it the blank lines before.
    func paragraphObject(at cursor: Int, around: Bool, in buffer: VimTextBuffer) -> NSRange? {
        let lineCount = buffer.lineCount
        let currentLine = buffer.lineAndColumn(forOffset: cursor).line
        let blank = lineIsBlank(currentLine, in: buffer)
        var startLine = currentLine
        while startLine > 0 && lineIsBlank(startLine - 1, in: buffer) == blank { startLine -= 1 }
        var endLine = currentLine
        while endLine < lineCount - 1 && lineIsBlank(endLine + 1, in: buffer) == blank { endLine += 1 }
        if around {
            var next = endLine
            while next < lineCount - 1 && lineIsBlank(next + 1, in: buffer) != blank { next += 1 }
            if next > endLine {
                endLine = next
            } else if !blank {
                while startLine > 0 && lineIsBlank(startLine - 1, in: buffer) { startLine -= 1 }
            }
        }
        let start = buffer.offset(forLine: startLine, column: 0)
        let end = NSMaxRange(buffer.lineRange(forOffset: buffer.offset(forLine: endLine, column: 0)))
        return NSRange(location: start, length: end - start)
    }
}
