//
//  VimEngine+Operators.swift
//  TablePro
//

import Foundation

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

        let rangeStart = min(startPos, endPos)
        var rangeEnd = max(startPos, endPos)
        if inclusive && rangeEnd < buffer.length && buffer.character(at: rangeEnd) != 0x0A {
            rangeEnd += 1
        }
        let range = NSRange(location: rangeStart, length: rangeEnd - rangeStart)

        executeOperatorOnRange(op, range: range, linewise: false, in: buffer)
        pendingOperator = nil
    }

    func executeOperatorOnRange(_ op: VimOperator, range: NSRange, linewise: Bool, in buffer: VimTextBuffer) {
        guard range.length > 0 else { return }

        switch op {
        case .delete:
            let text = buffer.string(in: range)
            writeToActiveRegister(text: text, linewise: linewise, asDelete: true)
            buffer.replaceCharacters(in: range, with: "")
            adjustMarksForEdit(in: range, replacementLength: 0)
            let newPos = min(range.location, max(0, buffer.length - 1))
            buffer.setSelectedRange(NSRange(location: max(0, newPos), length: 0))
        case .yank:
            let text = buffer.string(in: range)
            writeToActiveRegister(text: text, linewise: linewise, asDelete: false)
            buffer.setSelectedRange(NSRange(location: range.location, length: 0))
        case .change:
            let text = buffer.string(in: range)
            writeToActiveRegister(text: text, linewise: linewise, asDelete: true)
            buffer.replaceCharacters(in: range, with: "")
            adjustMarksForEdit(in: range, replacementLength: 0)
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
            let lineRange = nsText.lineRange(for: NSRange(location: lineStart, length: 0))
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
        adjustMarksForEdit(in: deleteRange, replacementLength: 0)
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
        adjustMarksForEdit(in: deleteRange, replacementLength: 0)
        buffer.replaceCharacters(in: deleteRange, with: "")
        buffer.setSelectedRange(NSRange(location: startRange.location, length: 0))
        setMode(.insert)
    }

    func paste(after: Bool, in buffer: VimTextBuffer) {
        let source = activePasteRegister()
        guard !source.text.isEmpty else { return }

        let pos = buffer.selectedRange().location

        if source.isLinewise {
            if after {
                let lineRange = buffer.lineRange(forOffset: pos)
                let insertPos = lineRange.location + lineRange.length
                var text = source.text
                let nsText = text as NSString
                if nsText.length == 0 || nsText.character(at: nsText.length - 1) != 0x0A {
                    text += "\n"
                }
                buffer.replaceCharacters(in: NSRange(location: insertPos, length: 0), with: text)
                buffer.setSelectedRange(NSRange(location: insertPos, length: 0))
            } else {
                let lineRange = buffer.lineRange(forOffset: pos)
                var text = source.text
                let nsText = text as NSString
                if nsText.length == 0 || nsText.character(at: nsText.length - 1) != 0x0A {
                    text += "\n"
                }
                buffer.replaceCharacters(in: NSRange(location: lineRange.location, length: 0), with: text)
                buffer.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            }
        } else {
            if after {
                let insertPos = min(pos + 1, buffer.length)
                buffer.replaceCharacters(in: NSRange(location: insertPos, length: 0), with: source.text)
                let newPos = insertPos + (source.text as NSString).length - 1
                buffer.setSelectedRange(NSRange(location: max(insertPos, newPos), length: 0))
            } else {
                buffer.replaceCharacters(in: NSRange(location: pos, length: 0), with: source.text)
                let newPos = pos + (source.text as NSString).length - 1
                buffer.setSelectedRange(NSRange(location: max(pos, newPos), length: 0))
            }
        }
    }

    func deleteCharUnderCursor(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        let deleteCount = min(count, max(0, contentEnd - pos))
        guard deleteCount > 0 else { return }
        let range = NSRange(location: pos, length: deleteCount)
        writeToActiveRegister(text: buffer.string(in: range), linewise: false, asDelete: true)
        adjustMarksForEdit(in: range, replacementLength: 0)
        noteEdit(at: pos, in: buffer)
        buffer.replaceCharacters(in: range, with: "")
        let newContentEnd = contentEnd - deleteCount
        if pos >= newContentEnd && newContentEnd > lineRange.location {
            buffer.setSelectedRange(NSRange(location: newContentEnd - 1, length: 0))
        } else {
            buffer.setSelectedRange(NSRange(location: pos, length: 0))
        }
    }

    func deleteCharBeforeCursor(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let deleteCount = min(count, pos - lineRange.location)
        guard deleteCount > 0 else { return }
        let start = pos - deleteCount
        let range = NSRange(location: start, length: deleteCount)
        register.text = buffer.string(in: range)
        register.isLinewise = false
        register.syncToPasteboard()
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
        let deleteCount = min(count, max(0, contentEnd - pos))
        guard deleteCount > 0 else { setMode(.insert); return }
        let range = NSRange(location: pos, length: deleteCount)
        register.text = buffer.string(in: range)
        register.isLinewise = false
        register.syncToPasteboard()
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
        let toggleCount = min(count, max(0, contentEnd - pos))
        guard toggleCount > 0 else { return }
        let range = NSRange(location: pos, length: toggleCount)
        let transformed = toggleCaseTransform(buffer.string(in: range))
        buffer.replaceCharacters(in: range, with: transformed)
        let newPos = min(pos + toggleCount, contentEnd > lineRange.location ? contentEnd - 1 : lineRange.location)
        buffer.setSelectedRange(NSRange(location: newPos, length: 0))
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
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        guard pos + count <= contentEnd else { return true }
        let replacement: String
        if char == "\r" || char == "\n" {
            replacement = String(repeating: "\n", count: count)
        } else {
            replacement = String(repeating: char, count: count)
        }
        let range = NSRange(location: pos, length: count)
        buffer.replaceCharacters(in: range, with: replacement)
        buffer.setSelectedRange(NSRange(location: pos + count - 1, length: 0))
        return true
    }
}
