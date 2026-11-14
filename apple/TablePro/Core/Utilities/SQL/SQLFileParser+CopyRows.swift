//
//  SQLFileParser+CopyRows.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

extension SQLFileParser {
    static let defaultChunkSize = 65_536

    // A UTF-16 unit takes at most three UTF-8 bytes, so a piece of COPY rows stays within 1 MiB.
    static let defaultCopyPieceLength = 1_048_576 / 3

    struct ReadLimits {
        let batchCutLength: Int
        let chunkSize: Int
        let copyPieceLength: Int
    }

    // Reads the rows as psql 17 and 18 do (SQLPsqlScript.copyRows), from a buffer that holds part of the file.
    struct CopyRowsScanner {
        enum Step {
            // Read more, then scan again from the same start.
            case needsMoreText
            // `length` units of data, then `skipped` units that are never sent: the rest of the `;`'s line, or the
            // `\.` line with its line break.
            case advance(length: Int, skipped: Int, lineFeeds: Int, endsRows: Bool)
        }

        private let pieceLength: Int
        private var passesCommandLine = true
        // Where the scan stands relative to `start`, which stays put until a step hands units out.
        private var lineStart = 0
        private var searchedTo = 0
        private var lineFeeds = 0
        private var checksLine = true

        init(pieceLength: Int) {
            // A cut inside a line steps back off a lead surrogate and must still take a unit.
            self.pieceLength = max(2, pieceLength)
        }

        mutating func scan(_ text: NSString, from start: Int, atEndOfInput: Bool) -> Step {
            let available = text.length - start
            if passesCommandLine {
                return passCommandLine(text, from: start, available: available, atEndOfInput: atEndOfInput)
            }
            while true {
                if checksLine {
                    if lineStart >= pieceLength {
                        return cut(at: lineStart, insideLine: false)
                    }
                    if available - lineStart < SQLPsqlScript.endOfDataMarkerLookahead, !atEndOfInput {
                        return .needsMoreText
                    }
                    if let markerEnd = SQLPsqlScript.endOfDataMarker(in: text, at: start + lineStart, length: text.length) {
                        return endAtMarker(text, from: start, markerEnd: markerEnd)
                    }
                    if lineStart == available {
                        return .advance(length: lineStart, skipped: 0, lineFeeds: lineFeeds, endsRows: true)
                    }
                    checksLine = false
                    searchedTo = lineStart
                }
                let found = text.range(
                    of: "\n",
                    options: .literal,
                    range: NSRange(location: start + searchedTo, length: available - searchedTo)
                )
                guard found.location != NSNotFound else {
                    if available > pieceLength {
                        return cutBeforeOverflow(text, from: start)
                    }
                    if atEndOfInput {
                        return .advance(length: available, skipped: 0, lineFeeds: lineFeeds, endsRows: true)
                    }
                    searchedTo = available
                    return .needsMoreText
                }
                let lineEnd = found.location - start + 1
                if lineEnd > pieceLength {
                    return cutBeforeOverflow(text, from: start)
                }
                lineFeeds += 1
                lineStart = lineEnd
                checksLine = true
            }
        }

        private mutating func passCommandLine(
            _ text: NSString,
            from start: Int,
            available: Int,
            atEndOfInput: Bool
        ) -> Step {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: start, length: available))
            if found.location != NSNotFound {
                passesCommandLine = false
                return .advance(length: 0, skipped: found.location - start + 1, lineFeeds: 1, endsRows: false)
            }
            guard available > 0 || atEndOfInput else { return .needsMoreText }
            return .advance(length: 0, skipped: available, lineFeeds: 0, endsRows: atEndOfInput)
        }

        // The line being read runs past the piece: end the piece at the line before it, or inside it when it is the
        // piece's first.
        private mutating func cutBeforeOverflow(_ text: NSString, from start: Int) -> Step {
            if lineStart > 0 {
                return cut(at: lineStart, insideLine: false)
            }
            let splitsPair = UTF16.isLeadSurrogate(text.character(at: start + pieceLength - 1))
            return cut(at: splitsPair ? pieceLength - 1 : pieceLength, insideLine: true)
        }

        private mutating func cut(at length: Int, insideLine: Bool) -> Step {
            let step = Step.advance(length: length, skipped: 0, lineFeeds: lineFeeds, endsRows: false)
            lineStart = 0
            searchedTo = 0
            lineFeeds = 0
            checksLine = !insideLine
            return step
        }

        private func endAtMarker(_ text: NSString, from start: Int, markerEnd: Int) -> Step {
            var end = markerEnd
            var feeds = lineFeeds
            if end < text.length, text.character(at: end) == SqlLexer.carriageReturn {
                end += 1
            }
            if end < text.length, text.character(at: end) == SqlLexer.newline {
                end += 1
                feeds += 1
            }
            return .advance(length: lineStart, skipped: end - start - lineStart, lineFeeds: feeds, endsRows: true)
        }
    }
}

extension SQLFileParser.ParserContext {
    // SQL resumes on the line after a COPY's rows with nothing of a statement read.
    mutating func resumeAfterCopyRows() {
        SQLFileParser.resetStatement(&self)
        state = .normal
        lineHasCode = false
        lineHoldsOnlyBlanks = true
        previousUnit = SQLFileParser.kNewline
        previousUnitInWord = false
        pendingSlashLine = false
        pendingSlashTrailing.removeAll()
        separatorLineSearched = 0
    }
}
