//
//  VimEngine+Operators.swift
//  TablePro
//

import Foundation
import TableProTextEngine

extension VimEngine {
    func executeOperatorWithMotion(
        _ op: VimOperator,
        motion: () -> Void,
        inclusive: Bool = false,
        in buffer: VimTextBuffer
    ) {
        let startPos = buffer.selectedRange().location
        motion()
        let endPos = buffer.selectedRange().location
        operate(op, from: startPos, to: endPos, kind: inclusive ? .inclusive : .exclusive, in: buffer)
    }

    func operate(_ op: VimOperator, from origin: Int, to target: Int, kind: VimMotionKind, in buffer: VimTextBuffer) {
        pendingOperator = nil
        let start = min(origin, target)
        let end = max(origin, target)
        if kind == .linewise {
            executeOperatorOnRange(op, range: wholeLines(from: start, through: end, in: buffer), linewise: true, in: buffer)
            return
        }
        var rangeEnd = end
        if kind == .inclusive, end < buffer.length, buffer.character(at: end) != 0x0A {
            rangeEnd = characterEnd(at: end, in: buffer)
        }
        let startsInIndent = isInIndent(start, in: buffer)
        // `:help exclusive`: an exclusive motion that ends at the start of a later line stops at the end of the line
        // before, and takes whole lines when it starts in the indent.
        if kind == .exclusive, end > start, buffer.lineRange(forOffset: end).location == end {
            if startsInIndent {
                executeOperatorOnRange(op, range: wholeLines(from: start, through: end - 1, in: buffer), linewise: true, in: buffer)
                return
            }
            rangeEnd = characterStart(at: end - 1, in: buffer)
        }
        // `>` and `<` shift the lines the motion covers whatever its kind.
        if op == .indent || op == .outdent {
            let lines = wholeLines(from: start, through: max(start, rangeEnd - 1), in: buffer)
            executeOperatorOnRange(op, range: lines, linewise: true, in: buffer)
            return
        }
        // A delete over several lines from the indent to the end of a line takes the lines, as Vim's `d` does.
        if op == .delete, startsInIndent, rangeEnd > start,
           buffer.lineRange(forOffset: start).location != buffer.lineRange(forOffset: rangeEnd - 1).location,
           isBlankToLineEnd(from: rangeEnd, in: buffer) {
            executeOperatorOnRange(op, range: wholeLines(from: start, through: rangeEnd - 1, in: buffer), linewise: true, in: buffer)
            return
        }
        executeOperatorOnRange(op, range: NSRange(location: start, length: rangeEnd - start), linewise: false, in: buffer)
    }

    func wholeLines(from start: Int, through end: Int, in buffer: VimTextBuffer) -> NSRange {
        let first = buffer.lineRange(forOffset: start).location
        let last = NSMaxRange(buffer.lineRange(forOffset: max(start, end)))
        return NSRange(location: first, length: last - first)
    }

    // Only blanks come before `offset` on its line.
    func isInIndent(_ offset: Int, in buffer: VimTextBuffer) -> Bool {
        var scan = buffer.lineRange(forOffset: offset).location
        while scan < offset {
            let ch = buffer.character(at: scan)
            guard ch == 0x20 || ch == 0x09 else { return false }
            scan += 1
        }
        return true
    }

    func isBlankToLineEnd(from offset: Int, in buffer: VimTextBuffer) -> Bool {
        let lineEnd = contentEnd(ofLineAt: offset, in: buffer)
        var scan = offset
        while scan < lineEnd {
            let ch = buffer.character(at: scan)
            guard ch == 0x20 || ch == 0x09 || ch == 0x0D else { return false }
            scan += 1
        }
        return true
    }

    func executeOperatorOnRange(_ op: VimOperator, range proposed: NSRange, linewise: Bool, in buffer: VimTextBuffer) {
        guard proposed.length > 0 else { return }
        // Text objects scan by code unit, so their ranges can end inside a character.
        let start = characterStart(at: proposed.location, in: buffer)
        let range = NSRange(location: start, length: characterEnd(at: NSMaxRange(proposed) - 1, in: buffer) - start)

        switch op {
        case .delete:
            let text = buffer.string(in: range)
            writeToActiveRegister(text: text, linewise: linewise, asDelete: true)
            buffer.replaceCharacters(in: range, with: "")
            let landing = linewise ? firstNonBlankOffset(from: range.location, in: buffer) : range.location
            buffer.setSelectedRange(NSRange(location: clampToContentPosition(landing, in: buffer), length: 0))
        case .yank:
            let text = buffer.string(in: range)
            writeToActiveRegister(text: text, linewise: linewise, asDelete: false)
            buffer.setSelectedRange(NSRange(location: range.location, length: 0))
        case .change:
            let text = buffer.string(in: range)
            writeToActiveRegister(text: text, linewise: linewise, asDelete: true)
            // A linewise change leaves one empty line to type on, as `cc` does.
            let keepsLineBreak = linewise && NSMaxRange(range) <= buffer.length && range.length > 0
                && buffer.character(at: NSMaxRange(range) - 1) == 0x0A
            let deleted = keepsLineBreak ? NSRange(location: range.location, length: range.length - 1) : range
            buffer.replaceCharacters(in: deleted, with: "")
            buffer.setSelectedRange(NSRange(location: range.location, length: 0))
            setMode(.insert)
        case .lowercase:
            let transformed = buffer.string(in: range).lowercased()
            buffer.replaceCharacters(in: range, with: transformed)
            buffer.setSelectedRange(NSRange(location: range.location, length: 0))
        case .uppercase:
            let transformed = buffer.string(in: range).uppercased()
            buffer.replaceCharacters(in: range, with: transformed)
            buffer.setSelectedRange(NSRange(location: range.location, length: 0))
        case .toggleCase:
            let transformed = toggleCaseTransform(buffer.string(in: range))
            buffer.replaceCharacters(in: range, with: transformed)
            buffer.setSelectedRange(NSRange(location: range.location, length: 0))
        case .indent:
            applyIndent(in: range, outdent: false, in: buffer)
        case .outdent:
            applyIndent(in: range, outdent: true, in: buffer)
        }
    }

    func toggleCaseTransform(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            let char = Character(scalar)
            if char.isUppercase {
                result.append(char.lowercased())
            } else if char.isLowercase {
                result.append(char.uppercased())
            } else {
                result.append(char)
            }
        }
        return result
    }

    func applyIndent(in range: NSRange, outdent: Bool, in buffer: VimTextBuffer) {
        let indent = buffer.indentString()
        let nsText = buffer.string(in: range) as NSString
        var lines: [String] = []
        var lineStart = 0
        while lineStart < nsText.length {
            let lineRange = nsText.lineRangeBreakingAtLineEndings(for: NSRange(location: lineStart, length: 0))
            lines.append(nsText.substring(with: lineRange))
            lineStart = lineRange.location + lineRange.length
        }
        let transformed = lines.map { line -> String in
            if outdent {
                if line.hasPrefix(indent) { return String(line.dropFirst(indent.count)) }
                let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
                return String(stripped)
            }
            return indent + line
        }.joined()
        buffer.replaceCharacters(in: range, with: transformed)
        let firstNonBlank = firstNonBlankOffset(from: range.location, in: buffer)
        buffer.setSelectedRange(NSRange(location: firstNonBlank, length: 0))
    }

    func deleteLine(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let startRange = buffer.lineRange(forOffset: pos)
        var endOffset = startRange.location + startRange.length
        for _ in 1..<count {
            if endOffset < buffer.length {
                let nextLineRange = buffer.lineRange(forOffset: endOffset)
                endOffset = nextLineRange.location + nextLineRange.length
            }
        }
        let deleteRange = NSRange(location: startRange.location, length: endOffset - startRange.location)
        writeToActiveRegister(text: buffer.string(in: deleteRange), linewise: true, asDelete: true)
        buffer.replaceCharacters(in: deleteRange, with: "")
        let newPos = min(startRange.location, max(0, buffer.length - 1))
        if buffer.length > 0 {
            buffer.setSelectedRange(NSRange(location: newPos, length: 0))
        } else {
            buffer.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    func yankLine(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let startRange = buffer.lineRange(forOffset: pos)
        var endOffset = startRange.location + startRange.length
        for _ in 1..<count {
            if endOffset < buffer.length {
                let nextLineRange = buffer.lineRange(forOffset: endOffset)
                endOffset = nextLineRange.location + nextLineRange.length
            }
        }
        let yankRange = NSRange(location: startRange.location, length: endOffset - startRange.location)
        writeToActiveRegister(text: buffer.string(in: yankRange), linewise: true, asDelete: false)
    }

    func changeLine(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let startRange = buffer.lineRange(forOffset: pos)
        var endOffset = startRange.location + startRange.length
        for _ in 1..<count {
            if endOffset < buffer.length {
                let nextLineRange = buffer.lineRange(forOffset: endOffset)
                endOffset = nextLineRange.location + nextLineRange.length
            }
        }
        let deleteEnd = endOffset > startRange.location && endOffset <= buffer.length
            && buffer.character(at: endOffset - 1) == 0x0A ? endOffset - 1 : endOffset
        let deleteRange = NSRange(location: startRange.location, length: deleteEnd - startRange.location)
        writeToActiveRegister(text: buffer.string(in: deleteRange), linewise: true, asDelete: true)
        buffer.replaceCharacters(in: deleteRange, with: "")
        buffer.setSelectedRange(NSRange(location: startRange.location, length: 0))
        setMode(.insert)
    }

    // The register is read once, so a count pastes copies of the one register, and the copies go in as one run.
    func paste(after: Bool, count: Int, in buffer: VimTextBuffer) {
        let source = activePasteRegister()
        guard !source.text.isEmpty else { return }
        let copies = max(1, count)
        let pos = buffer.selectedRange().location

        if source.isLinewise {
            var line = source.text
            if (line as NSString).character(at: (line as NSString).length - 1) != 0x0A { line += "\n" }
            var text = String(repeating: line, count: copies)
            let lineRange = buffer.lineRange(forOffset: pos)
            var insertPos = after ? NSMaxRange(lineRange) : lineRange.location
            var firstLine = insertPos
            // Below a last line with no line break, the break goes before the pasted lines.
            if after, insertPos == buffer.length, insertPos > lineRange.location,
               buffer.character(at: insertPos - 1) != 0x0A {
                text = "\n" + text.dropLast()
                firstLine = insertPos + 1
            }
            buffer.replaceCharacters(in: NSRange(location: insertPos, length: 0), with: text)
            insertPos = firstLine
            buffer.setSelectedRange(NSRange(location: firstNonBlankOffset(from: insertPos, in: buffer), length: 0))
            return
        }

        let text = String(repeating: source.text, count: copies)
        // On an empty line the caret is on the line break, and `p` puts the text before it.
        let insertPos = after && pos < contentEnd(ofLineAt: pos, in: buffer) ? characterEnd(at: pos, in: buffer) : pos
        buffer.replaceCharacters(in: NSRange(location: insertPos, length: 0), with: text)
        let length = (text as NSString).length
        // Text over several lines leaves the cursor at its start, a single line on its last character.
        let landing = text.contains("\n") ? insertPos : characterStart(at: insertPos + length - 1, in: buffer)
        buffer.setSelectedRange(NSRange(location: landing, length: 0))
    }

    func deleteCharUnderCursor(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        let end = characterOffset(after: pos, count: count, limit: contentEnd, in: buffer)
        guard end > pos else { return }
        let range = NSRange(location: pos, length: end - pos)
        writeToActiveRegister(text: buffer.string(in: range), linewise: false, asDelete: true)
        noteEdit(at: pos, in: buffer)
        buffer.replaceCharacters(in: range, with: "")
        let newContentEnd = contentEnd - range.length
        if pos >= newContentEnd && newContentEnd > lineRange.location {
            buffer.setSelectedRange(NSRange(location: characterStart(at: newContentEnd - 1, in: buffer), length: 0))
        } else {
            buffer.setSelectedRange(NSRange(location: pos, length: 0))
        }
    }

    func deleteCharBeforeCursor(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let start = characterOffset(before: pos, count: count, limit: lineRange.location, in: buffer)
        guard start < pos else { return }
        let range = NSRange(location: start, length: pos - start)
        writeToActiveRegister(text: buffer.string(in: range), linewise: false, asDelete: true)
        buffer.replaceCharacters(in: range, with: "")
        buffer.setSelectedRange(NSRange(location: start, length: 0))
    }

    func substituteChars(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        let end = characterOffset(after: pos, count: count, limit: contentEnd, in: buffer)
        guard end > pos else { setMode(.insert); return }
        let range = NSRange(location: pos, length: end - pos)
        writeToActiveRegister(text: buffer.string(in: range), linewise: false, asDelete: true)
        buffer.replaceCharacters(in: range, with: "")
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
        setMode(.insert)
    }

    func toggleCaseUnderCursor(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        let end = characterOffset(after: pos, count: count, limit: contentEnd, in: buffer)
        guard end > pos else { return }
        let range = NSRange(location: pos, length: end - pos)
        let transformed = toggleCaseTransform(buffer.string(in: range))
        buffer.replaceCharacters(in: range, with: transformed)
        // A case change can change the length, as ß becomes SS.
        let newEnd = pos + (transformed as NSString).length
        let newContentEnd = contentEnd + newEnd - end
        let lastCharacter = characterStart(at: newContentEnd - 1, in: buffer)
        buffer.setSelectedRange(NSRange(location: min(newEnd, lastCharacter), length: 0))
    }

    func applyCaseToLine(_ op: VimOperator, count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let startRange = buffer.lineRange(forOffset: pos)
        var endOffset = startRange.location + startRange.length
        for _ in 1..<count {
            if endOffset < buffer.length {
                let nextLineRange = buffer.lineRange(forOffset: endOffset)
                endOffset = nextLineRange.location + nextLineRange.length
            }
        }
        let lineEnd = endOffset
        let contentEnd = lineEnd > startRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        let range = NSRange(location: startRange.location, length: contentEnd - startRange.location)
        guard range.length > 0 else { return }
        let original = buffer.string(in: range)
        let transformed: String
        switch op {
        case .lowercase: transformed = original.lowercased()
        case .uppercase: transformed = original.uppercased()
        case .toggleCase: transformed = toggleCaseTransform(original)
        default: return
        }
        buffer.replaceCharacters(in: range, with: transformed)
        buffer.setSelectedRange(NSRange(location: startRange.location, length: 0))
    }

    func indentLine(_ count: Int, outdent: Bool, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let startRange = buffer.lineRange(forOffset: pos)
        var endOffset = startRange.location + startRange.length
        for _ in 1..<count {
            if endOffset < buffer.length {
                let nextLineRange = buffer.lineRange(forOffset: endOffset)
                endOffset = nextLineRange.location + nextLineRange.length
            }
        }
        let range = NSRange(location: startRange.location, length: endOffset - startRange.location)
        applyIndent(in: range, outdent: outdent, in: buffer)
    }

    func joinLines(_ count: Int, withSpace: Bool, in buffer: VimTextBuffer) {
        let joinCount = max(count - 1, 1)
        for _ in 0..<joinCount {
            guard performSingleJoin(withSpace: withSpace, in: buffer) else { return }
        }
    }

    func joinSelectedLines(withSpace: Bool, in buffer: VimTextBuffer) {
        let sel = buffer.selectedRange()
        let startLineRange = buffer.lineRange(forOffset: sel.location)
        let lastInclusiveOffset = max(sel.location, sel.location + sel.length - 1)
        let endLineRange = buffer.lineRange(forOffset: lastInclusiveOffset)
        let startLine = buffer.lineAndColumn(forOffset: startLineRange.location).line
        let endLine = buffer.lineAndColumn(forOffset: endLineRange.location).line
        let linesCovered = max(1, endLine - startLine + 1)
        buffer.setSelectedRange(NSRange(location: startLineRange.location, length: 0))
        let joins = max(linesCovered - 1, 1)
        for _ in 0..<joins {
            guard performSingleJoin(withSpace: withSpace, in: buffer) else { break }
        }
        setMode(.normal)
    }

    func performSingleJoin(withSpace: Bool, in buffer: VimTextBuffer) -> Bool {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        guard lineEnd < buffer.length else { return false }
        guard lineEnd > lineRange.location && buffer.character(at: lineEnd - 1) == 0x0A else {
            return false
        }
        let newlineOffset = lineEnd - 1
        var stripStart = lineEnd
        if withSpace {
            while stripStart < buffer.length {
                let ch = buffer.character(at: stripStart)
                if ch == 0x20 || ch == 0x09 { stripStart += 1 } else { break }
            }
        }
        let nextLineIsEmpty = stripStart >= buffer.length
            || buffer.character(at: stripStart) == 0x0A
        let lastContentOffset = newlineOffset
        let lastContent: unichar? = lastContentOffset > lineRange.location
            ? buffer.character(at: lastContentOffset - 1) : nil
        let lastIsWhitespace = lastContent == 0x20 || lastContent == 0x09
        let currentLineIsEmpty = lineEnd == lineRange.location + 1 && lastContent == nil
        let nextChar: unichar? = stripStart < buffer.length
            ? buffer.character(at: stripStart) : nil
        let nextIsClosingParen = nextChar == 0x29
        let shouldInsertSpace = withSpace
            && !nextLineIsEmpty
            && !lastIsWhitespace
            && !nextIsClosingParen
            && !currentLineIsEmpty
        let replacementRange = NSRange(location: newlineOffset, length: stripStart - newlineOffset)
        let replacement = shouldInsertSpace ? " " : ""
        buffer.replaceCharacters(in: replacementRange, with: replacement)
        let clamped = min(newlineOffset, max(0, buffer.length - 1))
        buffer.setSelectedRange(NSRange(location: clamped, length: 0))
        return true
    }

    func executeReplaceChar(_ char: Character, in buffer: VimTextBuffer) -> Bool {
        let count = consumeCount()
        guard !Self.isUnwritableControl(char) else { return true }
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        var end = pos
        for _ in 0..<count {
            guard end < contentEnd else { return true }
            end = characterEnd(at: end, in: buffer)
        }
        let unit = char == "\r" || char == "\n" ? "\n" : String(char)
        let replacement = String(repeating: unit, count: count)
        buffer.replaceCharacters(in: NSRange(location: pos, length: end - pos), with: replacement)
        let lastStart = pos + (replacement as NSString).length - (unit as NSString).length
        buffer.setSelectedRange(NSRange(location: lastStart, length: 0))
        return true
    }
}
