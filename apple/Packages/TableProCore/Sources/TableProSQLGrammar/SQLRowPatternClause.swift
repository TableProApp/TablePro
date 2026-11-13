import Foundation

// MATCH_RECOGNIZE's parentheses, read in the order Oracle takes them: PARTITION BY, ORDER BY, MEASURES, the rows per match,
// AFTER MATCH SKIP, PATTERN, SUBSET, DEFINE. A section word counts only after an operand, never after `.`, `AS`, a comma
// or an operator, so `AS subset` or `x.define` opens nothing; one that still lands out of order makes the clause
// unreadable. Nil when the clause does not read in that order, and a reader then takes it whole as an expression.
struct SQLRowPatternClause {
    // Token indices.
    private(set) var partitionBy: Range<Int>?
    private(set) var orderBy: Range<Int>?
    private(set) var measures: Range<Int>?
    let patternKeyword: Int
    let pattern: Range<Int>
    let define: Range<Int>

    private init(patternKeyword: Int, pattern: Range<Int>, define: Range<Int>) {
        self.patternKeyword = patternKeyword
        self.pattern = pattern
        self.define = define
    }

    private enum Section: Int {
        case partitionBy
        case orderBy
        case measures
        case rowsPerMatch
        case afterMatch
        case pattern
        case subset
        case define
    }

    private struct Mark {
        let section: Section
        let keyword: Int
        let content: Int
    }

    // `body` is the tokens inside the clause's parentheses.
    static func read(_ tokens: [TSQLTokens.Token], body: Range<Int>, text: NSString) -> SQLRowPatternClause? {
        guard let first = body.first else { return nil }
        let depth = tokens[first].depth
        var marks: [Mark] = []
        var index = body.lowerBound
        while index < body.upperBound {
            guard tokens[index].depth == depth, let mark = mark(at: index, in: tokens, body: body, text: text) else {
                index += 1
                continue
            }
            if let last = marks.last, mark.section.rawValue <= last.section.rawValue { return nil }
            marks.append(mark)
            if mark.section == .define { break }
            index = mark.content
        }
        guard let patternAt = marks.firstIndex(where: { $0.section == .pattern }),
              let define = marks.last, define.section == .define,
              let close = close(of: marks[patternAt].content, in: tokens, before: body.upperBound),
              marks[patternAt + 1].keyword == close + 1
        else { return nil }
        let keyword = marks[patternAt].keyword
        var clause = SQLRowPatternClause(
            patternKeyword: keyword,
            pattern: (marks[patternAt].content + 1)..<close,
            define: define.content..<body.upperBound
        )
        for (position, mark) in marks.enumerated() where mark.section.rawValue < Section.pattern.rawValue {
            let content = mark.content..<marks[position + 1].keyword
            switch mark.section {
            case .partitionBy: clause.partitionBy = content
            case .orderBy: clause.orderBy = content
            case .measures: clause.measures = content
            default: break
            }
        }
        return clause
    }

    private static func mark(
        at index: Int,
        in tokens: [TSQLTokens.Token],
        body: Range<Int>,
        text: NSString
    ) -> Mark? {
        guard let word = tokens[index].word else { return nil }
        let next = index + 1 < body.upperBound ? tokens[index + 1] : nil
        let section: Section
        switch word {
        case "PARTITION" where next?.word == "BY":
            section = .partitionBy
        case "ORDER" where next?.word == "BY":
            section = .orderBy
        case "MEASURES":
            section = .measures
        case "ONE" where next?.word == "ROW", "ALL" where next?.word == "ROWS":
            section = .rowsPerMatch
        case "AFTER" where next?.word == "MATCH":
            section = .afterMatch
        // Its content starts at the parenthesis.
        case "PATTERN" where next?.kind == .open:
            section = .pattern
        case "SUBSET":
            section = .subset
        case "DEFINE":
            section = .define
        default:
            return nil
        }
        guard index == body.lowerBound || followsOperand(tokens[index - 1], text: text) else { return nil }
        let length = section == .partitionBy || section == .orderBy ? 2 : 1
        return Mark(section: section, keyword: index, content: index + length)
    }

    private static let operatorWords: Set<String> = [
        "AS", "AND", "OR", "NOT", "IS", "IN", "LIKE", "BETWEEN", "CASE", "WHEN", "THEN", "ELSE", "BY", "MEASURES",
        "SUBSET", "DEFINE", "PATTERN", "RUNNING", "FINAL", "PRIOR", "DISTINCT", "ALL", "ANY", "SOME", "EXISTS", "ESCAPE",
    ]

    private static func followsOperand(_ token: TSQLTokens.Token, text: NSString) -> Bool {
        switch token.kind {
        case .close, .name, .quoted:
            return true
        case .word(let word):
            return !operatorWords.contains(word)
        case .other:
            let unit = text.character(at: token.location)
            return unit >= 0x30 && unit <= 0x39
        case .open, .comma, .terminator:
            return false
        }
    }

    private static func close(of open: Int, in tokens: [TSQLTokens.Token], before end: Int) -> Int? {
        guard open < end, tokens[open].kind == .open else { return nil }
        return ((open + 1)..<end).first { tokens[$0].kind == .close && tokens[$0].depth == tokens[open].depth }
    }
}
