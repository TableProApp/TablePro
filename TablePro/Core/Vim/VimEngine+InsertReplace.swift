//
//  VimEngine+InsertReplace.swift
//  TablePro
//

import Foundation

extension VimEngine {
    func processInsert(_ char: Character) -> Bool {
        if char == "\u{1B}" {
            lastInsertOffset = buffer?.selectedRange().location
            setMode(.normal)
            if let buffer, buffer.selectedRange().location > 0 {
                let pos = buffer.selectedRange().location
                let lineRange = buffer.lineRange(forOffset: pos)
                if pos > lineRange.location {
                    buffer.setSelectedRange(NSRange(location: pos - 1, length: 0))
                }
            }
            return true
        }
        if let buffer, handleInsertModeControl(char, in: buffer) {
            return true
        }
        return false
    }

    func processReplace(_ char: Character) -> Bool {
        guard let buffer else { return false }
        if char == "\u{1B}" {
            setMode(.normal)
            let pos = buffer.selectedRange().location
            let lineRange = buffer.lineRange(forOffset: pos)
            if pos > lineRange.location {
                buffer.setSelectedRange(NSRange(location: pos - 1, length: 0))
            }
            return true
        }
        if handleInsertModeControl(char, in: buffer) { return true }
        if char == "\r" || char == "\n" {
            return false
        }
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        if pos < contentEnd {
            buffer.replaceCharacters(in: NSRange(location: pos, length: 1), with: String(char))
        } else {
            buffer.replaceCharacters(in: NSRange(location: pos, length: 0), with: String(char))
        }
        return true
    }

    func processCommandLine(_ char: Character, buffer commandBuffer: String) -> Bool {
        switch char {
        case "\u{1B}":
            setMode(.normal)
            return true
        case "\r", "\n":
            let prefix = commandBuffer.first
            let body = String(commandBuffer.dropFirst())
            setMode(.normal)
            if prefix == "/" {
                runSearch(pattern: body, forward: true)
            } else if prefix == "?" {
                runSearch(pattern: body, forward: false)
            } else {
                onCommand?(body)
            }
            return true
        case "\u{7F}":
            if (commandBuffer as NSString).length > 1 {
                setMode(.commandLine(buffer: String(commandBuffer.dropLast())))
            } else {
                setMode(.normal)
            }
            return true
        default:
            setMode(.commandLine(buffer: commandBuffer + String(char)))
            return true
        }
    }

    func handleInsertModeControl(_ char: Character, in buffer: VimTextBuffer) -> Bool {
        switch char {
        case "\u{17}":
            deleteWordBackwardInInsert(in: buffer)
            return true
        case "\u{15}":
            deleteToLineStartInInsert(in: buffer)
            return true
        case "\u{08}":
            backspaceInInsert(in: buffer)
            return true
        case "\u{14}":
            indentLineInInsert(outdent: false, in: buffer)
            return true
        case "\u{04}":
            indentLineInInsert(outdent: true, in: buffer)
            return true
        default:
            return false
        }
    }

    func deleteWordBackwardInInsert(in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        guard pos > 0 else { return }
        let lineStart = buffer.lineRange(forOffset: pos).location
        guard pos > lineStart else { return }
        let target = max(lineStart, buffer.wordBoundary(forward: false, from: pos))
        let range = NSRange(location: target, length: pos - target)
        buffer.replaceCharacters(in: range, with: "")
        buffer.setSelectedRange(NSRange(location: target, length: 0))
    }

    func deleteToLineStartInInsert(in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineStart = buffer.lineRange(forOffset: pos).location
        guard pos > lineStart else { return }
        let range = NSRange(location: lineStart, length: pos - lineStart)
        buffer.replaceCharacters(in: range, with: "")
        buffer.setSelectedRange(NSRange(location: lineStart, length: 0))
    }

    func backspaceInInsert(in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        guard pos > 0 else { return }
        buffer.replaceCharacters(in: NSRange(location: pos - 1, length: 1), with: "")
        buffer.setSelectedRange(NSRange(location: pos - 1, length: 0))
    }

    func indentLineInInsert(outdent: Bool, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let indent = buffer.indentString()
        if outdent {
            let line = buffer.string(in: lineRange) as NSString
            var stripCount = 0
            while stripCount < indent.count && stripCount < line.length
                && (line.character(at: stripCount) == 0x20 || line.character(at: stripCount) == 0x09) {
                stripCount += 1
            }
            guard stripCount > 0 else { return }
            buffer.replaceCharacters(in: NSRange(location: lineRange.location, length: stripCount), with: "")
            buffer.setSelectedRange(NSRange(location: max(lineRange.location, pos - stripCount), length: 0))
        } else {
            buffer.replaceCharacters(in: NSRange(location: lineRange.location, length: 0), with: indent)
            buffer.setSelectedRange(NSRange(location: pos + indent.count, length: 0))
        }
    }
}
