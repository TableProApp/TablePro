import Foundation
import TableProSQLGrammar

// A literal or quoted name runs to its closer here, and stops at the end of a chunk when the next one decides it.
extension SQLFileParser {
    static func processAlternativeQuote(
        _ ctx: inout ParserContext,
        i: inout Int,
        nsBuffer: NSString,
        bufLen: Int
    ) -> StepResult {
        let start = i
        var pos = i
        while pos < bufLen {
            let ch = nsBuffer.character(at: pos)
            if pos > start && ch == kNewline {
                ctx.currentLine += 1
            }
            if ch == ctx.alternativeQuoteCloser {
                let quoteAt = pos + (ctx.alternativeQuoteCloserTrail == nil ? 1 : 2)
                if quoteAt >= bufLen {
                    if ctx.atEndOfInput {
                        pos += 1
                        continue
                    }
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: true)
                }
                let trailMatches = ctx.alternativeQuoteCloserTrail.map { nsBuffer.character(at: pos + 1) == $0 } ?? true
                if trailMatches, nsBuffer.character(at: quoteAt) == kSingleQuote {
                    pos = quoteAt + 1
                    ctx.state = .normal
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: false)
                }
            }
            pos += 1
        }
        appendRange(&ctx, from: start, to: pos, in: nsBuffer)
        i = pos
        return StepResult(advanced: true, deferred: false)
    }

    /// Runs a triple-quoted literal to the three quotes that close it, holding back a quote or a backslash the buffer
    /// ends on until the next chunk shows what follows.
    static func processTripleQuotedString(
        _ ctx: inout ParserContext,
        i: inout Int,
        nsBuffer: NSString,
        bufLen: Int
    ) -> StepResult {
        let start = i
        var pos = i
        while pos < bufLen {
            let ch = nsBuffer.character(at: pos)
            if pos > start && ch == kNewline {
                ctx.currentLine += 1
            }
            if ctx.backslashEscapesActive && ch == kBackslash {
                guard pos + 1 < bufLen || ctx.atEndOfInput else {
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: true)
                }
                pos += 2
                continue
            }
            if ch == ctx.quoteChar {
                guard pos + 2 < bufLen || ctx.atEndOfInput else {
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: true)
                }
                if SqlLexer.startsTripleQuote(nsBuffer, at: pos, length: bufLen) {
                    pos += 3
                    ctx.state = .normal
                    ctx.backslashEscapesActive = false
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: false)
                }
            }
            pos += 1
        }
        appendRange(&ctx, from: start, to: min(pos, bufLen), in: nsBuffer)
        i = min(pos, bufLen)
        return StepResult(advanced: true, deferred: false)
    }

    /// Runs a `[...]` identifier to its `]`, which `]]` does not close where the grammar escapes it.
    static func processBracketedIdentifier(
        _ ctx: inout ParserContext,
        i: inout Int,
        nsBuffer: NSString,
        bufLen: Int
    ) -> StepResult {
        let start = i
        var pos = i
        let doubledEscapes = ctx.grammar.contains(.doubledClosingBracketEscapes)
        while pos < bufLen {
            let ch = nsBuffer.character(at: pos)
            if pos > start && ch == kNewline {
                ctx.currentLine += 1
            }
            guard ch == kCloseBracket else {
                pos += 1
                continue
            }
            if doubledEscapes {
                guard pos + 1 < bufLen || ctx.atEndOfInput else {
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: true)
                }
                if pos + 1 < bufLen, nsBuffer.character(at: pos + 1) == kCloseBracket {
                    pos += 2
                    continue
                }
            }
            pos += 1
            ctx.state = .normal
            appendRange(&ctx, from: start, to: pos, in: nsBuffer)
            i = pos
            return StepResult(advanced: true, deferred: false)
        }
        appendRange(&ctx, from: start, to: pos, in: nsBuffer)
        i = pos
        return StepResult(advanced: true, deferred: false)
    }

    static func processQuotedString(
        _ ctx: inout ParserContext,
        quoteChar: unichar,
        i: inout Int,
        nsBuffer: NSString,
        bufLen: Int
    ) -> StepResult {
        let start = i
        var pos = i
        let escapesActive = ctx.backslashEscapesActive

        while pos < bufLen {
            let ch = nsBuffer.character(at: pos)
            if pos > start && ch == kNewline {
                ctx.currentLine += 1
            }

            if escapesActive && ch == kBackslash {
                if pos + 1 >= bufLen {
                    if ctx.atEndOfInput {
                        pos += 1
                        continue
                    }
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: true)
                }
                let next = nsBuffer.character(at: pos + 1)
                if next == kNewline { ctx.currentLine += 1 }
                pos += 2
                continue
            }

            if ch == quoteChar {
                if pos + 1 >= bufLen && !ctx.atEndOfInput {
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: true)
                }
                let next: unichar? = pos + 1 < bufLen ? nsBuffer.character(at: pos + 1) : nil
                if next == quoteChar {
                    pos += 2
                    continue
                }
                pos += 1
                ctx.state = .normal
                ctx.backslashEscapesActive = false
                appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                i = pos
                return StepResult(advanced: true, deferred: false)
            }

            pos += 1
        }

        appendRange(&ctx, from: start, to: pos, in: nsBuffer)
        i = pos
        return StepResult(advanced: true, deferred: false)
    }

    static func processDollarQuote(
        _ ctx: inout ParserContext,
        i: inout Int,
        nsBuffer: NSString,
        bufLen: Int
    ) -> StepResult {
        let start = i
        var pos = i
        let closeLen = (ctx.dollarTag as NSString).length + 2

        while pos < bufLen {
            let ch = nsBuffer.character(at: pos)
            if pos > start && ch == kNewline {
                ctx.currentLine += 1
            }

            if ch == kDollar {
                if pos + closeLen > bufLen {
                    if ctx.atEndOfInput {
                        pos += 1
                        continue
                    }
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: true)
                }
                if SqlDollarQuote.matchesClose(at: pos, tag: ctx.dollarTag, in: nsBuffer, bufLen: bufLen) {
                    pos += closeLen
                    ctx.state = .normal
                    ctx.dollarTag = ""
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: false)
                }
            }
            pos += 1
        }

        appendRange(&ctx, from: start, to: pos, in: nsBuffer)
        i = pos
        return StepResult(advanced: true, deferred: false)
    }
}
