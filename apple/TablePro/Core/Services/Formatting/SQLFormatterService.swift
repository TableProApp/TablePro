//
//  SQLFormatterService.swift
//  TablePro
//

import Foundation

protocol SQLFormatterProtocol {
    func format(
        _ sql: String,
        dialect: DatabaseType,
        cursorOffset: Int?,
        options: SQLFormatterOptions
    ) throws -> SQLFormatterResult
}

struct SQLFormatterService: SQLFormatterProtocol {
    private static let maxInputSize = 10 * 1_024 * 1_024

    func format(
        _ sql: String,
        dialect: DatabaseType,
        cursorOffset: Int? = nil,
        options: SQLFormatterOptions = .default
    ) throws -> SQLFormatterResult {
        guard sql.utf8.count <= Self.maxInputSize else {
            throw SQLFormatterError.internalError("SQL too large (max \(Self.maxInputSize / 1_024 / 1_024)MB)")
        }

        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SQLFormatterError.emptyInput
        }

        let sqlLength = sql.utf16.count
        if let cursor = cursorOffset, cursor > sqlLength {
            throw SQLFormatterError.invalidCursorPosition(cursor, max: sqlLength)
        }

        let dialectProvider = SQLDialectFactory.createDialect(for: dialect)
        let dialectKeywords = dialectProvider.keywords
            .union(dialectProvider.functions)
            .union(dialectProvider.dataTypes)

        let tokenizer = SQLTokenizer(dialectKeywords: dialectKeywords)
        let tokens = tokenizer.tokenize(sql)
        var tokenFormatter = SQLTokenFormatter(
            options: options,
            dialectFunctions: dialectProvider.functions,
            dialectDataTypes: dialectProvider.dataTypes,
            rewritesFunctionCase: dialectProvider.functionNamesAreCaseInsensitive
        )
        let formatted = tokenFormatter.format(tokens)

        let newCursor = cursorOffset.map { original in
            mapCursorPosition(original: original, oldLength: sql.utf16.count, newLength: formatted.utf16.count)
        }

        return SQLFormatterResult(formattedSQL: formatted, cursorOffset: newCursor)
    }

    private func mapCursorPosition(original: Int, oldLength: Int, newLength: Int) -> Int {
        guard oldLength > 0 else { return 0 }
        let ratio = Double(original) / Double(oldLength)
        return min(Int(ratio * Double(newLength)), newLength)
    }
}

// SELECT, SET and WHERE lists are written inline and kept open until their clause ends, when one that
// overflows the line width gets its separators rewritten broken and its aliases aligned.
internal struct SQLTokenFormatter {
    let options: SQLFormatterOptions

    private static let builtinFunctions: Set<String> = [
        "COUNT", "SUM", "AVG", "MIN", "MAX",
    ]

    private static let builtinDataTypes: Set<String> = [
        "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT",
        "VARCHAR", "CHAR", "TEXT", "NVARCHAR", "NCHAR",
        "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL",
        "BOOLEAN", "BOOL", "BIT",
        "DATE", "TIME", "TIMESTAMP", "DATETIME", "INTERVAL",
        "BLOB", "CLOB", "BINARY", "VARBINARY",
        "JSON", "JSONB", "XML", "UUID",
        "SERIAL", "BIGSERIAL",
    ]

    // Width of `SELECT ` and `SET `, which the items after the first line up under.
    private static let selectAlignment = 7
    private static let setAlignment = 4

    private let functions: Set<String>
    private let dataTypes: Set<String>
    private let rewritesFunctionCase: Bool
    private let indentUnit: String

    init(
        options: SQLFormatterOptions,
        dialectFunctions: Set<String> = [],
        dialectDataTypes: Set<String> = [],
        rewritesFunctionCase: Bool
    ) {
        self.options = options
        self.functions = Self.builtinFunctions.union(dialectFunctions)
        self.dataTypes = Self.builtinDataTypes.union(dialectDataTypes)
        self.rewritesFunctionCase = rewritesFunctionCase
        self.indentUnit = options.indentUnit
    }

    private var output = FormatterOutput()
    private var clauseStack: [ClauseContext] = []
    private var afterNewline = true
    private var selectColumnPad = Pad(levels: 0)
    private var inSelectColumns = false
    private var skipCount = 0
    private var suppressNextSpace = false
    private var caseBasePad = Pad(levels: 0)
    private var selectColumnPadStack: [Pad] = []
    private var openLists: [PendingList] = []

    private enum ClauseContext {
        case select, from, where_, join, caseExpr, subquery, with
        case insert, update, set, createTable, createTableBody
        case inlineParen, windowParen
    }

    // Indent levels render as the indent unit, alignment spaces as spaces after them.
    private struct Pad {
        var levels: Int
        var spaces: Int = 0
    }

    private enum ListKind {
        case select, set, conditions
    }

    private struct Separator {
        let range: Range<Int>
        let broken: String
    }

    private struct PendingList {
        let kind: ListKind
        let depth: Int
        let lineStart: Int
        var separators: [Separator] = []
        var aliasOffsets: [Int: Int] = [:]
    }

    // True after BETWEEN, so the next AND stays inline.
    private var afterBetween = false

    private var newlinesAfterSemicolon: [Int: Int] = [:]

    // MARK: - Public

    mutating func format(_ tokens: [SQLToken]) -> String {
        newlinesAfterSemicolon.removeAll()
        var meaningfulIndex = -1
        for (i, token) in tokens.enumerated() {
            if token.type == .whitespace { continue }
            meaningfulIndex += 1
            if token.type == .punctuation && token.value == ";" {
                var nlCount = 0
                for j in (i + 1)..<tokens.count {
                    guard tokens[j].type == .whitespace else { break }
                    for c in tokens[j].value where c == "\n" { nlCount += 1 }
                }
                newlinesAfterSemicolon[meaningfulIndex] = nlCount
            }
        }

        let meaningful = tokens.compactMap { t -> SQLToken? in
            t.type == .whitespace ? nil : t
        }

        for mi in meaningful.indices {
            if skipCount > 0 {
                skipCount -= 1
                continue
            }

            let token = meaningful[mi]
            let next: SQLToken? = mi + 1 < meaningful.count ? meaningful[mi + 1] : nil
            let prev: SQLToken? = mi > 0 ? meaningful[mi - 1] : nil
            let next2: SQLToken? = mi + 2 < meaningful.count ? meaningful[mi + 2] : nil

            processToken(token, mi: mi, prev: prev, next: next, next2: next2)
        }

        closeLists(atOrDeeperThan: 0)
        return output.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Token Processing

    private mutating func processToken(_ token: SQLToken, mi: Int, prev: SQLToken?, next: SQLToken?, next2: SQLToken?) {
        switch token.type {
        case .comment:
            handleComment(token)
        case .punctuation:
            handlePunctuation(token, mi: mi, prev: prev, next: next)
        case .keyword:
            handleKeyword(token, prev: prev, next: next, next2: next2)
        default:
            appendToken(token.value)
        }
    }

    private mutating func handleComment(_ token: SQLToken) {
        if !afterNewline { newline() }
        output += token.value
        output += "\n"
        afterNewline = true
    }

    // MARK: - Punctuation

    private mutating func handlePunctuation(_ token: SQLToken, mi: Int, prev: SQLToken?, next: SQLToken?) {
        switch token.value {
        case ";":
            output += ";"
            closeLists(atOrDeeperThan: 0)
            let originalNewlines = newlinesAfterSemicolon[mi] ?? 0
            let newlineCount = min(max(originalNewlines, 1), 3)
            output += String(repeating: "\n", count: newlineCount)
            afterNewline = true
            clauseStack.removeAll()
            selectColumnPadStack.removeAll()
            inSelectColumns = false

        case ",":
            handleComma()

        case "(":
            handleOpenParen(next: next, prev: prev)

        case ")":
            handleCloseParen()

        case ".":
            output += "."
            afterNewline = false
            suppressNextSpace = true

        default:
            appendToken(token.value)
        }
    }

    private mutating func handleComma() {
        if inSelectColumns && currentContext == .select {
            appendCommaSeparator(kind: .select, alignedTo: selectColumnPad)
        } else if currentContext == .set {
            appendCommaSeparator(kind: .set, alignedTo: Pad(levels: indent, spaces: Self.setAlignment))
        } else if currentContext == .createTableBody {
            switch options.commaPosition {
            case .trailing:
                output += ",\n"
                afterNewline = true
            case .leading:
                output += "\n" + render(Pad(levels: indent)) + ","
                afterNewline = false
                suppressNextSpace = false
            }
        } else {
            output += ","
        }
    }

    private mutating func appendCommaSeparator(kind: ListKind, alignedTo pad: Pad) {
        let broken: String
        switch options.commaPosition {
        case .trailing:
            broken = ",\n" + render(pad)
        case .leading:
            broken = "\n" + render(Pad(levels: pad.levels, spaces: max(pad.spaces - 2, 0))) + ", "
        }
        appendSeparator(kind: kind, inline: ", ", broken: broken)
        afterNewline = false
        suppressNextSpace = true
    }

    private mutating func handleOpenParen(next: SQLToken?, prev: SQLToken?) {
        if next?.upperValue == "SELECT" {
            output += suppressNextSpace ? "(" : " ("
            openBlock()
            return
        }
        if prev?.upperValue == "AS" && clauseStack.contains(.with) {
            output += " ("
            openBlock()
            return
        }
        if clauseStack.contains(.createTable) && !clauseStack.contains(.createTableBody) {
            output += " ("
            output += "\n"
            afterNewline = true
            suppressNextSpace = false
            clauseStack.append(.createTableBody)
            return
        }
        if prev?.upperValue == "OVER" {
            output += "("
            afterNewline = false
            suppressNextSpace = true
            clauseStack.append(.windowParen)
            return
        }
        // A structural keyword takes a space before its paren (`VALUES (`, `IN (`); a function call
        // or a sized type does not (`COUNT(*)`, `VARCHAR(255)`).
        if let prevUpper = prev?.upperValue, prev?.type == .keyword,
           !functions.contains(prevUpper), !dataTypes.contains(prevUpper) {
            output += suppressNextSpace ? "(" : " ("
        } else if currentContext == .insert && prev?.type == .identifier {
            output += " ("
        } else {
            output += "("
        }
        afterNewline = false
        suppressNextSpace = true
        clauseStack.append(.inlineParen)
    }

    private mutating func openBlock() {
        output += "\n"
        selectColumnPadStack.append(selectColumnPad)
        afterNewline = true
        suppressNextSpace = false
        clauseStack.append(.subquery)
    }

    private mutating func handleCloseParen() {
        if currentContext == .inlineParen || currentContext == .windowParen {
            clauseStack.removeLast()
            output += ")"
            afterNewline = false
            suppressNextSpace = false
            return
        }
        if let idx = clauseStack.lastIndex(where: Self.isBlockContext) {
            closeLists(atOrDeeperThan: indent)
            clauseStack.removeSubrange(idx...)
            output += "\n" + indentStr() + ")"
            afterNewline = false
            inSelectColumns = clauseStack.contains(.select)
            if let saved = selectColumnPadStack.popLast() {
                selectColumnPad = saved
            }
            suppressNextSpace = false
            return
        }
        output += ")"
        afterNewline = false
        suppressNextSpace = false
    }

    // MARK: - Keywords

    private mutating func handleKeyword(_ token: SQLToken, prev: SQLToken?, next: SQLToken?, next2: SQLToken?) {
        // A word beside a dot is part of a qualified name (`e.end`, `dbo.len(x)`, `key.id`), and a
        // name keeps its spelling on an engine with case-sensitive identifiers.
        if prev?.value == "." || next?.value == "." {
            appendToken(token.value)
            return
        }
        let upper = token.upperValue
        let kw = options.keywordCase.applied(upper: upper, original: token.value)

        switch upper {
        case "SELECT":
            handleSelect(kw: kw, prev: prev)
        case "FROM":
            handleFrom(kw: kw, prev: prev)
        case "WHERE":
            handleClauseKeyword(kw: kw, context: .where_, list: .conditions)
        case "AND", "OR":
            handleAndOr(kw: kw, upper: upper)
        case "JOIN":
            handleClauseKeyword(kw: kw, context: .join)
        case "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL":
            handleJoinPrefix(token, kw: kw, next: next, next2: next2)
        case "OUTER":
            break // absorbed by the JOIN prefix handler
        case "ON":
            handleOn(kw: kw)
        case "OVER", "PARTITION", "BY", "ALL", "INTO", "TABLE":
            appendToken(kw)
        case "AS":
            recordAliasIfTopLevel()
            appendToken(kw)
        case "BETWEEN":
            afterBetween = true
            appendToken(kw)
        case "ORDER", "GROUP":
            handleOrderGroup(kw: kw, next: next)
        case "HAVING", "LIMIT", "OFFSET":
            handleClauseKeyword(kw: kw, context: nil)
        case "UNION", "INTERSECT", "EXCEPT", "MINUS":
            handleSetOperation(upper: upper, kw: kw, next: next)
        case "CASE":
            handleCase(kw: kw)
        case "WHEN", "ELSE":
            handleWhenElse(kw: kw)
        case "THEN":
            output += " " + kw
            afterNewline = false
        case "END":
            handleEnd(kw: kw)
        case "WITH":
            handleWith(kw: kw, prev: prev)
        case "INSERT":
            handleInsert(kw: kw, prev: prev, next: next)
        case "VALUES":
            // `a = VALUES(a)` in MySQL's ON DUPLICATE KEY UPDATE is a function call.
            if prev?.type != .operator { newline() }
            appendToken(kw)
        case "UPDATE":
            handleStatementStart(kw: kw, prev: prev, context: .update)
        case "SET":
            handleClauseKeyword(kw: kw, context: .set, list: .set)
        case "DELETE":
            handleStatementStart(kw: kw, prev: prev, context: nil)
        case "CREATE":
            handleStatementStart(kw: kw, prev: prev, context: .createTable)
        default:
            appendToken(cased(token, next: next))
        }
    }

    // `count` and `date` can name columns, so only a call takes the function case, and only where the
    // engine accepts any spelling of the function.
    private func cased(_ token: SQLToken, next: SQLToken?) -> String {
        let upper = token.upperValue
        if functions.contains(upper) {
            guard rewritesFunctionCase, next?.value == "(" else { return token.value }
            return options.functionCase.applied(upper: upper, original: token.value)
        }
        if dataTypes.contains(upper) {
            return token.value
        }
        return options.keywordCase.applied(upper: upper, original: token.value)
    }

    private mutating func handleSelect(kw: String, prev: SQLToken?) {
        // `GRANT SELECT, INSERT ON t`, `CREATE POLICY p ON t FOR SELECT`
        if let prev, Self.statementKeywordModifiers.contains(prev.upperValue) {
            appendToken(kw)
            return
        }
        closeLists(atOrDeeperThan: indent)
        if !afterNewline { newline() }
        let lineStart = output.count
        output += indentStr() + kw
        afterNewline = false
        inSelectColumns = true
        selectColumnPad = Pad(levels: indent, spaces: Self.selectAlignment)
        clauseStack.append(.select)
        openLists.append(PendingList(kind: .select, depth: indent, lineStart: lineStart))
    }

    private mutating func handleFrom(kw: String, prev: SQLToken?) {
        // `EXTRACT(YEAR FROM d)`, `SUBSTRING(s FROM 2)`, `TRIM(BOTH ' ' FROM s)`
        if isInsideNestedExpression {
            appendToken(kw)
            return
        }
        closeLists(atOrDeeperThan: indent)
        inSelectColumns = false
        newline()
        appendToken(kw)
        if prev?.upperValue != "DELETE" {
            replaceTop(with: .from)
        }
    }

    private mutating func handleClauseKeyword(kw: String, context: ClauseContext?, list: ListKind? = nil) {
        // `FILTER (WHERE ...)`, `(a JOIN b ON ...)`, `name TEXT CHARACTER SET utf8mb4`
        if isInsideNestedExpression {
            appendToken(kw)
            return
        }
        closeLists(atOrDeeperThan: indent)
        inSelectColumns = false
        newline()
        let lineStart = output.count
        appendToken(kw)
        if let ctx = context { replaceTop(with: ctx) }
        if let list {
            openLists.append(PendingList(kind: list, depth: indent, lineStart: lineStart))
        }
    }

    private mutating func handleAndOr(kw: String, upper: String) {
        if upper == "AND" && afterBetween {
            afterBetween = false
            output += " " + kw
            afterNewline = false
            return
        }
        guard currentContext == .where_ else {
            output += " " + kw
            afterNewline = false
            return
        }
        let pad = Pad(levels: indent + 1)
        if afterNewline {
            output += render(pad) + kw
        } else {
            appendSeparator(kind: .conditions, inline: " ", broken: "\n" + render(pad))
            output += kw
        }
        afterNewline = false
    }

    private mutating func handleJoinPrefix(_ token: SQLToken, kw: String, next: SQLToken?, next2: SQLToken?) {
        let upper = token.upperValue
        let joinWords: String
        if next?.upperValue == "OUTER" && next2?.upperValue == "JOIN" {
            joinWords = "\(upper) OUTER JOIN"
            skipCount = 2
        } else if next?.upperValue == "JOIN" {
            joinWords = "\(upper) JOIN"
            skipCount = 1
        } else {
            // `LEFT(name, 3)`, `RIGHT(code, 2)`
            appendToken(cased(token, next: next))
            return
        }
        let joinKw = options.keywordCase.synthesized(joinWords)
        if isInsideNestedExpression {
            appendToken(joinKw)
            return
        }
        closeLists(atOrDeeperThan: indent)
        inSelectColumns = false
        newline()
        appendToken(joinKw)
        replaceTop(with: .join)
    }

    private mutating func handleOn(kw: String) {
        if currentContext == .join && options.joinCondition == .newLine {
            newline()
            output += render(Pad(levels: indent + 1)) + kw
        } else {
            output += " " + kw
        }
        afterNewline = false
    }

    private mutating func handleOrderGroup(kw: String, next: SQLToken?) {
        // Window specs and aggregates keep it inline: `OVER (ORDER BY x)`, `STRING_AGG(a, ',' ORDER BY a)`
        if clauseStack.contains(.windowParen) || isInsideNestedExpression {
            if next?.upperValue == "BY" {
                let byKw = options.keywordCase.synthesized("BY")
                output += " " + kw + " " + byKw
                afterNewline = false
                skipCount = 1
            } else {
                appendToken(kw)
            }
            return
        }
        closeLists(atOrDeeperThan: indent)
        inSelectColumns = false
        if next?.upperValue == "BY" {
            let byKw = options.keywordCase.synthesized("BY")
            newline()
            output += indentStr() + kw + " " + byKw
            afterNewline = false
            skipCount = 1
        } else {
            appendToken(kw)
        }
    }

    private mutating func handleSetOperation(upper: String, kw: String, next: SQLToken?) {
        closeLists(atOrDeeperThan: indent)
        inSelectColumns = false
        if let blockIdx = clauseStack.lastIndex(where: Self.isBlockContext) {
            clauseStack.removeSubrange((blockIdx + 1)...)
        } else {
            clauseStack.removeAll()
        }

        var line = kw
        if upper == "UNION" && next?.upperValue == "ALL" {
            let allKw = options.keywordCase.synthesized("ALL")
            line += " " + allKw
            skipCount = 1
        }

        if clauseStack.contains(where: Self.isBlockContext) {
            output += "\n" + indentStr() + line + "\n"
        } else {
            output += "\n\n" + line + "\n\n"
        }
        afterNewline = true
    }

    private mutating func handleCase(kw: String) {
        caseBasePad = inSelectColumns ? selectColumnPad : Pad(levels: indent)
        appendToken(kw)
        clauseStack.append(.caseExpr)
    }

    private mutating func handleWhenElse(kw: String) {
        let whenPad = Pad(levels: caseBasePad.levels + 1, spaces: caseBasePad.spaces)
        output += "\n" + render(whenPad) + kw
        afterNewline = false
        suppressNextSpace = false
    }

    private mutating func handleEnd(kw: String) {
        if clauseStack.last == .caseExpr { clauseStack.removeLast() }
        output += "\n" + render(caseBasePad) + kw
        afterNewline = false
    }

    private mutating func handleWith(kw: String, prev: SQLToken?) {
        // `TIMESTAMP WITH TIME ZONE` in a column list or a cast is a type, not a CTE.
        guard startStatement(kw: kw, prev: prev) else { return }
        clauseStack.append(.with)
    }

    private mutating func handleInsert(kw: String, prev: SQLToken?, next: SQLToken?) {
        guard startStatement(kw: kw, prev: prev) else { return }
        if next?.upperValue == "INTO" {
            output += " " + options.keywordCase.synthesized("INTO")
            skipCount = 1
        }
        clauseStack.append(.insert)
    }

    private mutating func handleStatementStart(kw: String, prev: SQLToken?, context: ClauseContext?) {
        guard startStatement(kw: kw, prev: prev) else { return }
        if let ctx = context { clauseStack.append(ctx) }
    }

    // Inside parentheses, a column list or after a word it modifies, a statement keyword is part of a
    // clause: `ON DELETE CASCADE`, `FOR UPDATE`, `ON DUPLICATE KEY UPDATE`, `BEFORE INSERT ON t`.
    private static let statementKeywordModifiers: Set<String> = [
        "ON", "FOR", "KEY", "BEFORE", "AFTER", "OF", "GRANT", "REVOKE", "WITH", ",",
    ]

    private mutating func startStatement(kw: String, prev: SQLToken?) -> Bool {
        if isInsideNestedExpression || prev.map({ Self.statementKeywordModifiers.contains($0.upperValue) }) == true {
            appendToken(kw)
            return false
        }
        if !afterNewline { newline() }
        output += indentStr() + kw
        afterNewline = false
        suppressNextSpace = false
        return true
    }

    // MARK: - Lists

    private mutating func appendSeparator(kind: ListKind, inline: String, broken: String) {
        let start = output.count
        guard let index = openLists.lastIndex(where: { $0.kind == kind && $0.depth == indent }) else {
            output += broken
            return
        }
        output += inline
        openLists[index].separators.append(Separator(range: start..<output.count, broken: broken))
    }

    private mutating func recordAliasIfTopLevel() {
        guard inSelectColumns, currentContext == .select, !afterNewline,
              let index = openLists.lastIndex(where: { $0.kind == .select && $0.depth == indent })
        else { return }
        let column = openLists[index].separators.count
        if openLists[index].aliasOffsets[column] == nil {
            openLists[index].aliasOffsets[column] = output.count
        }
    }

    private mutating func closeLists(atOrDeeperThan depth: Int) {
        while let list = openLists.last, list.depth >= depth {
            openLists.removeLast()
            close(list)
        }
    }

    private mutating func close(_ list: PendingList) {
        guard !list.separators.isEmpty else { return }
        let end = output.count
        if options.lineWidth > 0, fitsOnOneLine(list.lineStart..<end) { return }

        let aliasPadding = aliasPadding(for: list)
        var rebuilt: [UInt8] = []
        var cursor = list.lineStart
        for column in 0...list.separators.count {
            if let offset = list.aliasOffsets[column], let pad = aliasPadding[column], pad > 0 {
                rebuilt.append(contentsOf: output.bytes[cursor..<offset])
                rebuilt.append(contentsOf: repeatElement(UInt8(ascii: " "), count: pad))
                cursor = offset
            }
            guard column < list.separators.count else { break }
            let separator = list.separators[column]
            rebuilt.append(contentsOf: output.bytes[cursor..<separator.range.lowerBound])
            rebuilt.append(contentsOf: separator.broken.utf8)
            cursor = separator.range.upperBound
        }
        rebuilt.append(contentsOf: output.bytes[cursor..<end])
        output.replace(list.lineStart..<end, with: rebuilt)
    }

    private func fitsOnOneLine(_ range: Range<Int>) -> Bool {
        !output.containsNewline(in: range) && columns(of: output.text(in: range)) <= options.lineWidth
    }

    // A column whose expression spans lines keeps its alias where it is.
    private func aliasPadding(for list: PendingList) -> [Int: Int] {
        guard options.alignAliases, list.kind == .select, list.aliasOffsets.count > 1 else { return [:] }
        var widths: [Int: Int] = [:]
        for (column, offset) in list.aliasOffsets {
            let start = column == 0 ? list.lineStart : list.separators[column - 1].range.upperBound
            guard !output.containsNewline(in: start..<offset) else { continue }
            let leading = column == 0 ? "" : Self.lastLine(of: list.separators[column - 1].broken)
            widths[column] = columns(of: leading) + columns(of: output.text(in: start..<offset))
        }
        guard let target = widths.values.max() else { return [:] }
        return widths.mapValues { target - $0 }
    }

    private static func lastLine(of text: String) -> Substring {
        guard let newline = text.lastIndex(of: "\n") else { return Substring(text) }
        return text[text.index(after: newline)...]
    }

    private func columns<S: StringProtocol>(of text: S) -> Int {
        text.reduce(0) { $0 + ($1 == "\t" ? options.indentWidth : 1) }
    }

    // MARK: - Helpers

    private var currentContext: ClauseContext? { clauseStack.last }

    private var isInsideNestedExpression: Bool {
        currentContext == .inlineParen || currentContext == .windowParen || currentContext == .createTableBody
    }

    private static func isBlockContext(_ ctx: ClauseContext) -> Bool {
        ctx == .subquery || ctx == .createTableBody
    }

    private var indent: Int {
        clauseStack.reduce(into: 0) { depth, ctx in
            if Self.isBlockContext(ctx) { depth += 1 }
        }
    }

    private mutating func replaceTop(with ctx: ClauseContext) {
        if !clauseStack.isEmpty { clauseStack.removeLast() }
        clauseStack.append(ctx)
    }

    private func render(_ pad: Pad) -> String {
        String(repeating: indentUnit, count: max(pad.levels, 0)) + String(repeating: " ", count: max(pad.spaces, 0))
    }

    private func indentStr() -> String {
        render(Pad(levels: indent))
    }

    private mutating func newline() {
        output += "\n"
        afterNewline = true
    }

    private mutating func appendToken(_ value: String) {
        if afterNewline {
            output += indentStr() + value
        } else if suppressNextSpace {
            output += value
        } else {
            output += " " + value
        }
        afterNewline = false
        suppressNextSpace = false
    }
}

// Bytes, so rewriting a list costs the list's length. Splices fall between tokens, so the UTF-8 stays valid.
private struct FormatterOutput {
    private(set) var bytes: [UInt8] = []

    var count: Int { bytes.count }

    var string: String { String(decoding: bytes, as: UTF8.self) } // swiftlint:disable:this optional_data_string_conversion

    static func += (lhs: inout FormatterOutput, rhs: String) {
        lhs.bytes.append(contentsOf: rhs.utf8)
    }

    func containsNewline(in range: Range<Int>) -> Bool {
        bytes[range].contains(UInt8(ascii: "\n"))
    }

    func text(in range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
    }

    mutating func replace(_ range: Range<Int>, with replacement: [UInt8]) {
        bytes.replaceSubrange(range, with: replacement)
    }
}
