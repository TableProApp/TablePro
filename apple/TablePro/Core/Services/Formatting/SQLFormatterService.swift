//
//  SQLFormatterService.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

protocol SQLFormatterProtocol {
    func format(
        _ sql: String,
        dialect: DatabaseType,
        grammar: SQLLexicalGrammar?,
        cursorOffset: Int?,
        options: SQLFormatterOptions
    ) throws -> SQLFormatterResult
}

struct SQLFormatterService: SQLFormatterProtocol {
    private static let maxInputSize = 10 * 1_024 * 1_024

    // `grammar` is the one the tab's statements are split with; nil reads the engine's default.
    func format(
        _ sql: String,
        dialect: DatabaseType,
        grammar: SQLLexicalGrammar? = nil,
        cursorOffset: Int? = nil,
        options: SQLFormatterOptions = .default
    ) throws -> SQLFormatterResult {
        guard sql.utf8.count <= Self.maxInputSize else {
            throw SQLFormatterError.inputTooLarge(maxBytes: Self.maxInputSize)
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

        let tokenizer = SQLTokenizer(dialectKeywords: dialectKeywords, operators: dialectProvider.operators)
        let readGrammar = grammar ?? dialect.lexicalGrammar
        let tokens = tokenizer.tokenize(sql, grammar: readGrammar)
        var tokenFormatter = SQLTokenFormatter(
            options: options,
            dialectFunctions: dialectProvider.functions,
            dialectDataTypes: dialectProvider.dataTypes,
            rewritesFunctionCase: dialectProvider.functionNamesAreCaseInsensitive,
            rewritesDataTypeCase: dialectProvider.typeNamesAreCaseInsensitive
        )
        let readsDirectives = !readGrammar.isDisjoint(with: [.batchSeparatorLines, .delimiterDirective, .slashLineTerminators])
        let formatted = tokenFormatter.format(
            tokens,
            directiveLines: readsDirectives ? { tokenizer.directiveLines(in: $0, grammar: readGrammar) } : nil
        )

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

// SELECT, SET, WHERE and HAVING lists are written inline and kept open until their clause ends, when one that
// overflows the line width gets its separators rewritten broken and its aliases aligned. A block's body sits one level
// under the line its `(` is on, and a CASE lines up with the line it starts on.
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
        "DOUBLE PRECISION", "CHARACTER VARYING", "CHAR VARYING", "NATIONAL CHARACTER", "NATIONAL CHAR", "BIT VARYING",
        "TIMESTAMP WITH TIME ZONE", "TIMESTAMP WITHOUT TIME ZONE", "TIME WITH TIME ZONE", "TIME WITHOUT TIME ZONE",
    ]

    // Width of `SELECT ` and `SET `, which the items after the first line up under.
    private static let selectAlignment = 7
    private static let setAlignment = 4

    private let functions: Set<String>
    private let dataTypes: Set<String>
    // Multi-word types by their first word, longest first: `CHARACTER VARYING`, `TIMESTAMP WITH TIME ZONE`.
    private let typePhrases: [String: [[String]]]
    private let rewritesFunctionCase: Bool
    private let rewritesDataTypeCase: Bool
    private let indentUnit: String

    init(
        options: SQLFormatterOptions,
        dialectFunctions: Set<String> = [],
        dialectDataTypes: Set<String> = [],
        rewritesFunctionCase: Bool,
        rewritesDataTypeCase: Bool = false
    ) {
        self.options = options
        self.functions = Self.builtinFunctions.union(dialectFunctions)
        self.dataTypes = Self.builtinDataTypes.union(dialectDataTypes)
        var phrases: [String: [[String]]] = [:]
        for type in dataTypes where type.contains(" ") {
            let words = type.uppercased().split(separator: " ").map(String.init)
            if let first = words.first { phrases[first, default: []].append(words) }
        }
        self.typePhrases = phrases.mapValues { $0.sorted { $0.count > $1.count } }
        self.rewritesFunctionCase = rewritesFunctionCase
        self.rewritesDataTypeCase = rewritesDataTypeCase
        self.indentUnit = options.indentUnit
    }

    private var output = FormatterOutput()
    private var stream: [SQLToken] = []
    private var spacedBefore: [Bool] = []
    private var lineBrokenBefore: [Bool] = []
    private var position = 0
    private var clauseStack: [ClauseContext] = []
    private var afterNewline = true
    private var selectColumnPad = Pad(levels: 0)
    private var inSelectColumns = false
    private var skipCount = 0
    private var gluePosition: Int?
    private var casePads: [Pad] = []
    // The pad of the line each open block's `(` sits on.
    private var blockOpeners: [Pad] = []
    // The pad of the line being written, as it reads once its list breaks.
    private var linePad = Pad(levels: 0)
    private var pendingLead: (kind: ListKind, pad: Pad)?
    private var selectColumnPadStack: [Pad] = []
    private var openLists: [PendingList] = []
    // True between CREATE ... TABLE and its column list, so only that paren becomes a table body.
    private var awaitsTableBody = false
    // True between CREATE ... FUNCTION or PROCEDURE and its parameter list.
    private var awaitsParameterList = false
    // Where `@x <type>` declares a variable: a DECLARE, and a routine's header up to its AS or BEGIN. Anywhere else
    // the word after a variable is an alias (`FROM @rows date`).
    private var inDeclare = false
    private var inRoutineHeader = false
    // The word before each open inline paren, keyed by its index in `clauseStack`.
    private var parenOpeners: [Int: String] = [:]
    // The last token of the multi-word type being written, which takes the type's case as one word does.
    private var typePhraseEnd = -1
    private var directiveOffsets: [Int] = []

    private enum ClauseContext {
        case select, from, where_, join, caseExpr, subquery, with
        case insert, update, set, createTable, createTableBody
        case inlineParen, windowParen, clause
    }

    // Indent levels render as the indent unit, alignment spaces as spaces after them.
    private struct Pad {
        var levels: Int
        var spaces: Int = 0

        func adding(levels extraLevels: Int = 0, spaces extraSpaces: Int = 0) -> Pad {
            Pad(levels: levels + extraLevels, spaces: spaces + extraSpaces)
        }
    }

    private enum ListKind {
        case select, set, conditions, cte
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
        // The break between the clause keyword and its first item, when items go below the keyword.
        var hasLead = false
        var itemPad: Pad?
    }

    // True after BETWEEN, so the next AND stays inline.
    private var afterBetween = false

    private var newlinesAfterTerminator: [Int: Int] = [:]

    // The next token writes with no space before it only while nothing was written since this was set.
    private var suppressNextSpace: Bool {
        get { gluePosition == output.count }
        set { gluePosition = newValue ? output.count : nil }
    }

    // MARK: - Public

    // `directiveLines` reads the lines a text holds client directives on, under the grammar the tokens came from.
    mutating func format(_ tokens: [SQLToken], directiveLines: ((String) -> Set<Int>)? = nil) -> String {
        stream.removeAll()
        spacedBefore.removeAll()
        lineBrokenBefore.removeAll()
        newlinesAfterTerminator.removeAll()
        var pendingSpace = false
        var pendingBreak = false
        for (i, token) in tokens.enumerated() {
            if token.type == .whitespace {
                pendingSpace = true
                pendingBreak = pendingBreak || token.value.utf16.contains(0x0A)
                continue
            }
            if Self.isTerminator(token) {
                var count = 0
                for j in (i + 1)..<tokens.count {
                    guard tokens[j].type == .whitespace else { break }
                    count += tokens[j].value.utf16.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
                }
                newlinesAfterTerminator[stream.count] = count
            }
            stream.append(token)
            spacedBefore.append(pendingSpace)
            lineBrokenBefore.append(pendingBreak)
            pendingSpace = false
            pendingBreak = false
        }

        for index in stream.indices {
            if skipCount > 0 {
                skipCount -= 1
                continue
            }
            position = index
            processToken(stream[index], prev: token(at: index - 1), next: token(at: index + 1))
        }

        closeLists(atOrDeeperThan: 0)
        var text = output.string
        if let directiveLines {
            text = Self.joiningManufacturedDirectives(
                in: text,
                written: writtenDirectiveLines(),
                directiveLines: directiveLines
            )
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The line each directive was written on, counted in one pass: a script can hold tens of thousands of `GO` lines.
    private func writtenDirectiveLines() -> Set<Int> {
        var lines: Set<Int> = []
        var line = 0
        var cursor = 0
        for offset in directiveOffsets {
            while cursor < offset {
                if output.bytes[cursor] == UInt8(ascii: "\n") { line += 1 }
                cursor += 1
            }
            lines.insert(line)
        }
        return lines
    }

    // A word alone on a line can read as a client directive the input never had: a column named `go` left alone by
    // a leading comma is a `GO` batch separator, and the server then gets two broken batches. Such a line joins the
    // line before it, or the line after it when the one before is a line comment, so formatting adds no directive.
    private static func joiningManufacturedDirectives(
        in text: String,
        written: Set<Int>,
        directiveLines: (String) -> Set<Int>
    ) -> String {
        var lines = text.components(separatedBy: "\n")
        var kept = written
        // A join can leave `go` before a line that starts with a number, which reads as `GO 5`; one more pass fixes it.
        for _ in 0..<3 {
            let manufactured = directiveLines(lines.joined(separator: "\n")).subtracting(kept)
            guard !manufactured.isEmpty else { break }
            var joined: [String] = []
            joined.reserveCapacity(lines.count)
            var joinedKept: Set<Int> = []
            var index = 0
            while index < lines.count {
                let line = lines[index]
                defer { index += 1 }
                guard manufactured.contains(index) else {
                    if kept.contains(index) { joinedKept.insert(joined.count) }
                    joined.append(line)
                    continue
                }
                if let previous = joined.last, !joinedKept.contains(joined.count - 1), canTakeJoinedCode(previous) {
                    joined[joined.count - 1] = previous + " " + line.drop { $0 == " " || $0 == "\t" }
                } else if index + 1 < lines.count, !kept.contains(index + 1), canTakeJoinedCode(lines[index + 1]) {
                    joined.append(line + " " + lines[index + 1].drop { $0 == " " || $0 == "\t" })
                    index += 1
                } else {
                    joinedKept.insert(joined.count)
                    joined.append(line)
                }
            }
            lines = joined
            kept = joinedKept
        }
        return lines.joined(separator: "\n")
    }

    private static func canTakeJoinedCode(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.hasPrefix("--") && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("//")
    }

    private func token(at index: Int) -> SQLToken? {
        stream.indices.contains(index) ? stream[index] : nil
    }

    private var next2: SQLToken? {
        token(at: position + 2)
    }

    // The next token that is not a comment, for decisions that skip nothing.
    private var nextCode: SQLToken? {
        stream[(position + 1)...].first { $0.type != .comment }
    }

    // A custom delimiter (`DELIMITER //`) arrives as punctuation, like the `;` it stands in for.
    private static func isTerminator(_ token: SQLToken) -> Bool {
        token.type == .punctuation && !["(", ")", ",", "."].contains(token.value)
    }

    // MARK: - Token Processing

    private mutating func processToken(_ token: SQLToken, prev: SQLToken?, next: SQLToken?) {
        trackDeclarations(token)
        if let lead = pendingLead, token.type != .comment,
           !(lead.kind == .select && ["DISTINCT", "ALL"].contains(token.upperValue)),
           !(lead.kind == .cte && token.upperValue == "RECURSIVE") {
            pendingLead = nil
            if let index = openLists.lastIndex(where: { $0.kind == lead.kind && $0.depth == indent }) {
                openLists[index].hasLead = true
            }
            appendSeparator(kind: lead.kind, inline: " ", broken: "\n" + render(lead.pad))
            afterNewline = false
            suppressNextSpace = true
        }
        if position <= typePhraseEnd || startsTypePhrase() {
            appendToken(typeCased(token))
            return
        }
        switch token.type {
        case .comment:
            handleComment(token)
        case .directive:
            handleDirective(token)
        case .punctuation:
            handlePunctuation(token, prev: prev)
        case .keyword:
            handleKeyword(token, prev: prev, next: next)
        case .operator where token.value == "[":
            if afterNewline {
                output += indentStr() + "["
            } else {
                output += suppressNextSpace || !spacedBefore[position] ? "[" : " ["
            }
            afterNewline = false
            suppressNextSpace = true
            // An array's elements are not the items of the list it sits in: `ARRAY[1, 2]` stays on one line.
            parenOpeners[clauseStack.count] = "["
            clauseStack.append(.inlineParen)
        case .operator where token.value == "]":
            if currentContext == .inlineParen, parenOpeners[clauseStack.count - 1] == "[" {
                clauseStack.removeLast()
            }
            writeGlued("]")
        case .string where prev?.type == .string && lineBrokenBefore[position] && !afterNewline:
            // SQL joins two string literals only across a line break, and PostgreSQL refuses `'foo' 'bar'` on one line.
            let pad = linePad
            newline()
            linePad = pad
            output += render(pad) + token.value
            afterNewline = false
        case .string where !spacedBefore[position] && prev?.type == .identifier && !afterNewline:
            // `r'raw'`, `b'0101'`: a word written against a quote may introduce the literal, and apart it would not.
            output += token.value
            gluePosition = nil
        default:
            appendToken(token.value)
        }
    }

    private mutating func handleComment(_ token: SQLToken) {
        if !afterNewline { newline() }
        output += indentStr() + token.value + "\n"
        afterNewline = true
    }

    // A `GO` or `DELIMITER` line ends what came before it and stays a line of its own.
    private mutating func handleDirective(_ token: SQLToken) {
        closeLists(atOrDeeperThan: 0)
        if !afterNewline { newline() }
        directiveOffsets.append(output.count)
        output += token.value + "\n"
        afterNewline = true
        resetStatement()
    }

    private static let statementStarters: Set<String> = [
        "SELECT", "INSERT", "UPDATE", "DELETE", "MERGE", "SET", "WITH", "IF", "WHILE", "BEGIN", "END", "RETURN",
        "EXEC", "EXECUTE", "PRINT", "OPEN", "FETCH", "CLOSE", "CREATE", "ALTER", "DROP", "TRUNCATE",
    ]

    private mutating func trackDeclarations(_ token: SQLToken) {
        guard Self.isWord(token) else { return }
        let upper = token.upperValue
        if currentContext == .createTable, upper == "FUNCTION" || upper == "PROCEDURE" {
            awaitsParameterList = true
            inRoutineHeader = true
        } else if upper == "AS" || upper == "BEGIN" {
            inRoutineHeader = false
        }
        if upper == "DECLARE" {
            inDeclare = true
        } else if Self.statementStarters.contains(upper) {
            inDeclare = false
        }
    }

    private mutating func resetStatement() {
        clauseStack.removeAll()
        selectColumnPadStack.removeAll()
        blockOpeners.removeAll()
        casePads.removeAll()
        linePad = Pad(levels: 0)
        pendingLead = nil
        inSelectColumns = false
        awaitsTableBody = false
        awaitsParameterList = false
        inDeclare = false
        inRoutineHeader = false
        afterBetween = false
    }

    // MARK: - Punctuation

    private mutating func handlePunctuation(_ token: SQLToken, prev: SQLToken?) {
        switch token.value {
        case ",":
            handleComma()
        case "(":
            handleOpenParen(prev: prev)
        case ")":
            handleCloseParen()
        case ".":
            output += "."
            afterNewline = false
            suppressNextSpace = true
        default:
            handleTerminator(token)
        }
    }

    private mutating func handleTerminator(_ token: SQLToken) {
        if afterNewline {
            output += indentStr() + token.value
        } else {
            output += token.value == ";" ? ";" : " " + token.value
        }
        closeLists(atOrDeeperThan: 0)
        let originalNewlines = newlinesAfterTerminator[position] ?? 0
        let newlineCount = min(max(originalNewlines, 1), 3)
        output += String(repeating: "\n", count: newlineCount)
        afterNewline = true
        resetStatement()
    }

    private mutating func handleComma() {
        if inSelectColumns && currentContext == .select {
            appendCommaSeparator(kind: .select, alignedTo: selectColumnPad)
        } else if currentContext == .with && options.clauseItems == .newLine {
            appendCommaSeparator(kind: .cte, alignedTo: base.adding(levels: 1))
        } else if currentContext == .set {
            appendCommaSeparator(kind: .set, alignedTo: setItemPad)
        } else if currentContext == .createTableBody {
            switch options.commaPosition {
            case .trailing:
                output += ",\n"
                afterNewline = true
            case .leading:
                output += "\n" + indentStr() + ","
                afterNewline = false
                suppressNextSpace = false
            }
        } else {
            writeGlued(",")
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
        linePad = pad
        afterNewline = false
        suppressNextSpace = true
    }

    private mutating func handleOpenParen(prev: SQLToken?) {
        if nextCode?.upperValue == "SELECT" {
            writeOpener()
            openBlock()
            return
        }
        if prev?.upperValue == "AS" && clauseStack.contains(.with) {
            output += " ("
            openBlock()
            return
        }
        if awaitsTableBody {
            awaitsTableBody = false
            output += " (\n"
            afterNewline = true
            blockOpeners.append(linePad)
            clauseStack.append(.createTableBody)
            linePad = base
            return
        }
        if prev?.upperValue == "OVER" {
            writeGlued("(")
            suppressNextSpace = true
            clauseStack.append(.windowParen)
            return
        }
        let opener = awaitsParameterList ? Self.parameterListOpener : prev?.upperValue ?? ""
        awaitsParameterList = false
        // A structural keyword takes a space before its paren (`VALUES (`, `IN (`); a function call
        // or a sized type does not (`COUNT(*)`, `VARCHAR(255)`).
        if typePhraseEnd == position - 1 {
            writeGlued("(")
        } else if let prev, prev.type == .keyword, !functions.contains(prev.upperValue), !dataTypes.contains(prev.upperValue) {
            writeOpener()
        } else if currentContext == .insert && Self.isQuotedOrPlainName(prev) {
            writeOpener()
        } else if prev?.value == "," {
            writeOpener()
        } else {
            writeGlued("(")
        }
        suppressNextSpace = true
        parenOpeners[clauseStack.count] = opener
        clauseStack.append(.inlineParen)
    }

    private static func isQuotedOrPlainName(_ token: SQLToken?) -> Bool {
        guard let token else { return false }
        return token.type == .identifier || (token.type == .string && token.value.hasPrefix("\""))
    }

    private mutating func writeOpener() {
        if afterNewline {
            output += indentStr() + "("
        } else {
            output += suppressNextSpace ? "(" : " ("
        }
        afterNewline = false
    }

    private mutating func openBlock() {
        output += "\n"
        selectColumnPadStack.append(selectColumnPad)
        afterNewline = true
        blockOpeners.append(linePad)
        clauseStack.append(.subquery)
        linePad = base
    }

    private mutating func handleCloseParen() {
        if currentContext == .inlineParen || currentContext == .windowParen {
            clauseStack.removeLast()
            writeGlued(")")
            return
        }
        if let idx = clauseStack.lastIndex(where: Self.isBlockContext) {
            closeLists(atOrDeeperThan: indent)
            clauseStack.removeSubrange(idx...)
            let opener = blockOpeners.popLast() ?? Pad(levels: 0)
            output += (afterNewline ? "" : "\n") + render(opener) + ")"
            linePad = opener
            afterNewline = false
            inSelectColumns = clauseStack.contains(.select)
            if let saved = selectColumnPadStack.popLast() {
                selectColumnPad = saved
            }
            return
        }
        writeGlued(")")
    }

    // MARK: - Keywords

    private mutating func handleKeyword(_ token: SQLToken, prev: SQLToken?, next: SQLToken?) {
        // A word beside a dot is part of a qualified name (`e.end`, `dbo.len(x)`, `key.id`).
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
        case "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "OUTER":
            handleJoinPrefix(token, prev: prev, next: next)
        case "ON":
            handleOn(kw: kw)
        case "OVER", "PARTITION", "BY", "ALL", "INTO":
            appendToken(isName(token) ? token.value : kw)
        case "TABLE":
            if currentContext == .createTable { awaitsTableBody = true }
            appendToken(isName(token) ? token.value : kw)
        case "AS":
            awaitsTableBody = false
            recordAliasIfTopLevel()
            appendToken(kw)
        case "BETWEEN":
            afterBetween = true
            appendToken(kw)
        case "ORDER", "GROUP":
            handleOrderGroup(kw: kw, next: next)
        case "HAVING":
            handleClauseKeyword(kw: kw, context: .where_, list: .conditions)
        case "LIMIT", "OFFSET":
            handleClauseKeyword(kw: kw, context: .clause)
        case "UNION", "INTERSECT", "EXCEPT", "MINUS":
            handleSetOperation(upper: upper, kw: kw, next: next)
        case "CASE":
            handleCase(kw: kw)
        case "WHEN", "ELSE":
            handleWhenElse(kw: kw)
        case "THEN":
            appendToken(kw)
        case "END":
            handleEnd(kw: kw)
        case "WITH":
            handleWith(kw: kw, prev: prev)
        case "INSERT":
            handleInsert(kw: kw, prev: prev, next: next)
        case "VALUES":
            // `a = VALUES(a)` in MySQL's ON DUPLICATE KEY UPDATE is a function call.
            if prev?.type != .operator && !isInsideNestedExpression { breakLine() }
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
            appendToken(cased(token, prev: prev, next: next))
        }
    }

    // `count` and `date` can name columns, so only a call takes the function case, and a word standing where a name
    // stands keeps the spelling it was written in.
    private func cased(_ token: SQLToken, prev: SQLToken?, next: SQLToken?) -> String {
        let upper = token.upperValue
        if functions.contains(upper), next?.value == "(" {
            return rewritesFunctionCase ? options.functionCase.applied(upper: upper, original: token.value) : token.value
        }
        if isName(token) {
            return token.value
        }
        if dataTypes.contains(upper) {
            return isTypePosition(position) ? typeCased(token) : token.value
        }
        if functions.contains(upper) {
            return token.value
        }
        return options.keywordCase.applied(upper: upper, original: token.value)
    }

    // MARK: - Types

    private static let parameterListOpener = "(parameters)"
    private static let castFunctions: Set<String> = ["CAST", "TRY_CAST", "SAFE_CAST"]
    private static let parameterModes: Set<String> = ["IN", "OUT", "INOUT", "VARIADIC"]

    // A word spelled like a type is a type only where the grammar puts one: a column definition, `CAST(x AS t)`,
    // `x::t`, `RETURNS t`, `TYPE t`, a variable or parameter declaration, and the words that continue one
    // (`DOUBLE PRECISION`). Anywhere else it may name a column (`date + 1`, `ORDER BY date`), and a name keeps its
    // spelling.
    private func isTypePosition(_ index: Int) -> Bool {
        guard let prev = token(at: index - 1) else { return false }
        let prevUpper = prev.upperValue
        let beforePrev = token(at: index - 2)
        switch prevUpper {
        case "::", "RETURNS", "SETOF":
            return true
        case "TYPE":
            return beforePrev.map { ($0.type != .keyword && Self.isNameToken($0)) || $0.upperValue == "DATA" } ?? false
        case "AS":
            if let beforePrev, Self.isVariable(beforePrev), declaresVariables { return true }
            guard currentContext == .inlineParen, let opener = parenOpeners[clauseStack.count - 1] else { return false }
            return Self.castFunctions.contains(opener)
        default:
            break
        }
        if Self.isVariable(prev), declaresVariables { return true }
        let beforeUpper = beforePrev?.upperValue ?? ""
        // A table variable's or table type's columns: `DECLARE @t TABLE (a int)`, `RETURNS @t TABLE (a int)`.
        if currentContext == .inlineParen, parenOpeners[clauseStack.count - 1] == "TABLE",
           ["(", ","].contains(beforeUpper), Self.isNameToken(prev) {
            return true
        }
        if ["DECLARE", "COLUMN", "ADD", "MODIFY"].contains(beforeUpper), Self.isNameToken(prev), prevUpper != "IF" {
            return true
        }
        if currentContext == .createTableBody, ["(", ","].contains(beforeUpper), Self.isNameToken(prev) {
            return true
        }
        guard currentContext == .inlineParen, parenOpeners[clauseStack.count - 1] == Self.parameterListOpener else {
            return false
        }
        if Self.isNameToken(prev), ["(", ","].contains(beforeUpper) || Self.parameterModes.contains(beforeUpper) {
            return true
        }
        let next = token(at: index + 1)?.value
        return ["(", ","].contains(prevUpper) && (next == "," || next == ")")
    }

    private static func isWord(_ token: SQLToken) -> Bool {
        token.type == .identifier || token.type == .keyword
    }

    // A name as a declaration writes it: a word, or a quoted identifier (`"id"`, `[id]`, `` `id` ``). The tokenizer
    // keeps `"..."` a string, as the query fingerprint reads it.
    private static func isNameToken(_ token: SQLToken) -> Bool {
        isWord(token) || (token.type == .string && token.value.hasPrefix("\""))
    }

    private static func isVariable(_ token: SQLToken) -> Bool {
        token.type == .placeholder && token.value.hasPrefix("@") && !token.value.hasPrefix("@@")
    }

    private var declaresVariables: Bool {
        inDeclare || inRoutineHeader
    }

    private func typeCased(_ token: SQLToken) -> String {
        rewritesDataTypeCase ? options.dataTypeCase.applied(upper: token.upperValue, original: token.value) : token.value
    }

    // A multi-word type in a type position is one type: every word takes its case, and the `WITH` of
    // `TIMESTAMP WITH TIME ZONE` starts no statement.
    private mutating func startsTypePhrase() -> Bool {
        guard let candidates = typePhrases[stream[position].upperValue], Self.isWord(stream[position]) else { return false }
        let match = candidates.first { words in
            words.indices.dropFirst().allSatisfy { offset in
                token(at: position + offset).map { Self.isWord($0) && $0.upperValue == words[offset] } ?? false
            }
        }
        guard let match, isTypePosition(position) else { return false }
        typePhraseEnd = position + match.count - 1
        return true
    }

    // MARK: - Names

    // Values, actions and modifiers wherever they stand, never names (`SELECT DISTINCT *`, `ARRAY[1]`).
    private static let valueWords: Set<String> = [
        "NULL", "TRUE", "FALSE", "UNKNOWN", "DEFAULT", "MATCHED", "CASCADE", "RESTRICT", "DISTINCT", "ALL", "ARRAY",
        "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_USER", "SESSION_USER",
        "LOCALTIME", "LOCALTIMESTAMP", "SYSDATE", "SYSTIMESTAMP", "ROWNUM", "LEVEL",
    ]

    private static let operandStarters: Set<String> = [
        "SELECT", "DISTINCT", ",", "(", "BY", "WHERE", "AND", "OR", "ON", "HAVING", "WHEN", "THEN", "ELSE", "SET",
        "RETURNING", "FROM", "JOIN", "INTO", "UPDATE", "WITH",
        "=", "<>", "!=", "<", ">", "<=", ">=", "<=>", "+", "-", "*", "/", "%", "||",
    ]

    private static let operandEnders: Set<String> = [
        ",", ")", "FROM", "AS", "ASC", "DESC", "NULLS", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET",
        "UNION", "INTERSECT", "EXCEPT", "MINUS", "WINDOW", "AND", "OR", "THEN", "ELSE", "END", "WHEN", "ON", "USING",
        "SET", "VALUES", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL",
        "IN", "IS", "LIKE", "ILIKE", "BETWEEN", "NOT",
        "=", "<>", "!=", "<", ">", "<=", ">=", "<=>", "+", "-", "*", "/", "%", "||", "::", "[",
    ]

    private static let tableIntroducers: Set<String> = ["FROM", "JOIN", "UPDATE", "INTO"]

    // Words that come between those and the table: `FROM ONLY t`, `JOIN LATERAL f(x) a`, ClickHouse's `INTO TABLE t`.
    private static let tableModifiers: Set<String> = [
        "ONLY", "LATERAL", "TABLE", "TEMPORARY", "TEMP", "UNLOGGED", "IGNORE", "LOW_PRIORITY", "HIGH_PRIORITY",
        "DELAYED", "OUTFILE", "DUMPFILE",
    ]

    // What can end a select item or a table reference, so a word after it is that item's alias.
    private static func endsOperand(_ token: SQLToken) -> Bool {
        switch token.type {
        case .identifier, .number, .string, .placeholder:
            return true
        case .keyword:
            return token.upperValue == "END" || valueWords.contains(token.upperValue)
        default:
            return token.value == ")" || token.value == "]"
        }
    }

    private static let aliasEnders: Set<String> = [
        ",", ")", "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "INTERSECT", "EXCEPT",
        "MINUS", "WINDOW", "QUALIFY", "INTO", "ON", "USING", "SET", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS",
        "NATURAL", "OUTER", "PREWHERE", "SETTINGS", "FORMAT", "FETCH",
    ]

    // Words that follow a table reference without naming it: ClickHouse's `FROM t FINAL`, `GLOBAL ANY JOIN`.
    private static let tableReferenceModifiers: Set<String> = ["FINAL", "GLOBAL", "ANY", "ASOF", "SEMI", "ANTI", "PASTE"]

    // `SELECT 1 rows`, `SELECT x date FROM t`, `FROM t first WHERE`: an alias written without AS keeps its spelling.
    private func isImplicitAlias(_ upper: String, prev: SQLToken?, next: SQLToken?) -> Bool {
        guard [.select, .from, .join].contains(currentContext), let prev, Self.endsOperand(prev),
              !Self.tableReferenceModifiers.contains(upper)
        else {
            return false
        }
        guard let next else { return true }
        return Self.isTerminator(next) || Self.aliasEnders.contains(next.upperValue)
    }

    private static let constraintStarters: Set<String> = [
        "CONSTRAINT", "PRIMARY", "FOREIGN", "UNIQUE", "CHECK", "EXCLUDE", "PERIOD", "LIKE",
    ]

    // MySQL's `KEY idx (a)` against ClickHouse's `key String`.
    private static let indexStarters: Set<String> = ["KEY", "INDEX", "FULLTEXT", "SPATIAL"]

    // Engines that match names by exact case (ClickHouse, BigQuery tables, MySQL tables on Unix, SQL Server under a
    // case-sensitive collation) read a re-cased name as another name, and MySQL titles a result column with the
    // spelling it was selected by. So a keyword standing where a name stands keeps its spelling on every engine: an
    // operand alone between a clause or operator and what ends it (`SELECT database, table`, `table = 'hits'`), an
    // alias, a column in a column list.
    private func isName(_ token: SQLToken) -> Bool {
        let prev = stream[..<position].last { $0.type != .comment }
        let next = nextCode
        let upper = token.upperValue
        if Self.valueWords.contains(upper) { return false }
        if currentContext == .createTableBody, prev?.value == "(" || prev?.value == "," {
            if Self.constraintStarters.contains(upper) { return false }
            if Self.indexStarters.contains(upper), next?.value == "(" || next2?.value == "(" { return false }
            return true
        }
        if prev?.upperValue == "COLUMN" { return upper != "IF" }
        if prev?.upperValue == "AS" { return !isInsideNestedExpression && next?.value != "(" }
        if isImplicitAlias(upper, prev: prev, next: next) { return true }
        // `FROM apply a`: a word between FROM, JOIN, UPDATE or INTO and its alias names the table.
        if let prev, Self.tableIntroducers.contains(prev.upperValue), next?.type == .identifier,
           !Self.tableModifiers.contains(upper) {
            return true
        }
        guard let prev, Self.operandStarters.contains(prev.upperValue) else { return false }
        guard let next else { return true }
        return Self.operandEnders.contains(next.upperValue) || Self.isTerminator(next)
    }

    // MARK: - Clauses

    private mutating func handleSelect(kw: String, prev: SQLToken?) {
        // `GRANT SELECT, INSERT ON t`, `CREATE POLICY p ON t FOR SELECT`
        if let prev, Self.statementKeywordModifiers.contains(prev.upperValue) {
            appendToken(kw)
            return
        }
        awaitsTableBody = false
        closeLists(atOrDeeperThan: indent)
        if !afterNewline { newline() }
        let lineStart = output.count
        output += indentStr() + kw
        afterNewline = false
        inSelectColumns = true
        selectColumnPad = options.clauseItems == .sameLine
            ? base.adding(spaces: Self.selectAlignment)
            : base.adding(levels: 1)
        linePad = selectColumnPad
        clauseStack.append(.select)
        openLists.append(PendingList(kind: .select, depth: indent, lineStart: lineStart))
        if options.clauseItems == .newLine { pendingLead = (.select, selectColumnPad) }
    }

    private mutating func handleFrom(kw: String, prev: SQLToken?) {
        // `EXTRACT(YEAR FROM d)`, `SUBSTRING(s FROM 2)`, `TRIM(BOTH ' ' FROM s)`, `a IS DISTINCT FROM b`
        let isDistinctFrom = prev?.upperValue == "DISTINCT"
            && ["IS", "NOT"].contains(token(at: position - 2)?.upperValue ?? "")
        if isInsideNestedExpression || isDistinctFrom {
            appendToken(kw)
            return
        }
        closeLists(atOrDeeperThan: indent)
        inSelectColumns = false
        breakLine()
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
        breakLine()
        let lineStart = output.count
        appendToken(kw)
        if let context { replaceTop(with: context) }
        guard let list else { return }
        openLists.append(PendingList(kind: list, depth: indent, lineStart: lineStart))
        let itemPad: Pad
        switch (list, options.clauseItems) {
        case (_, .newLine):
            itemPad = base.adding(levels: 1)
        case (.set, .sameLine):
            itemPad = setItemPad
            linePad = itemPad
        case (_, .sameLine):
            itemPad = options.logicalOperatorNewline == .after
                ? base.adding(spaces: kw.count + 1)
                : base.adding(levels: 1)
        }
        openLists[openLists.count - 1].itemPad = itemPad
        if options.clauseItems == .newLine {
            linePad = itemPad
            pendingLead = (list, itemPad)
        }
    }

    private var setItemPad: Pad {
        options.clauseItems == .sameLine ? base.adding(spaces: Self.setAlignment) : base.adding(levels: 1)
    }

    private mutating func handleAndOr(kw: String, upper: String) {
        if upper == "AND" && afterBetween {
            afterBetween = false
            appendToken(kw)
            return
        }
        guard currentContext == .where_ else {
            appendToken(kw)
            return
        }
        let pad = openLists.last(where: { $0.kind == .conditions && $0.depth == indent })?.itemPad
            ?? base.adding(levels: 1)
        linePad = pad
        if afterNewline {
            output += render(pad) + kw
        } else if options.logicalOperatorNewline == .after {
            output += " " + kw
            appendSeparator(kind: .conditions, inline: " ", broken: "\n" + render(pad))
            afterNewline = false
            suppressNextSpace = true
            return
        } else {
            appendSeparator(kind: .conditions, inline: " ", broken: "\n" + render(pad))
            output += kw
        }
        afterNewline = false
    }

    // `LEFT JOIN`, `NATURAL LEFT OUTER JOIN`, `CROSS APPLY`, `OUTER APPLY`; anything else (`LEFT(name, 3)`, an
    // `OUTER` on its own) is written as a word.
    private mutating func handleJoinPrefix(_ token: SQLToken, prev: SQLToken?, next: SQLToken?) {
        guard let length = joinLength(from: position) else {
            appendToken(cased(token, prev: prev, next: next))
            return
        }
        let joinKw = stream[position..<(position + length)]
            .map { options.keywordCase.applied(upper: $0.upperValue, original: $0.value) }
            .joined(separator: " ")
        skipCount = length - 1
        if isInsideNestedExpression {
            appendToken(joinKw)
            return
        }
        closeLists(atOrDeeperThan: indent)
        inSelectColumns = false
        breakLine()
        appendToken(joinKw)
        replaceTop(with: .join)
    }

    private func joinLength(from start: Int) -> Int? {
        var index = start
        func word(_ offset: Int) -> String? {
            stream.indices.contains(offset) && stream[offset].type == .keyword ? stream[offset].upperValue : nil
        }
        if word(index) == "NATURAL" { index += 1 }
        if let side = word(index), ["LEFT", "RIGHT", "FULL", "INNER", "CROSS"].contains(side) { index += 1 }
        if word(index) == "OUTER" { index += 1 }
        guard index > start, let last = token(at: index), Self.isWord(last) else { return nil }
        if last.type == .keyword, last.upperValue == "JOIN" { return index - start + 1 }
        // APPLY is a word anywhere but right after CROSS or OUTER (`SELECT 1 apply`).
        if last.upperValue == "APPLY", let before = word(index - 1), before == "CROSS" || before == "OUTER" {
            return index - start + 1
        }
        return nil
    }

    private mutating func handleOn(kw: String) {
        if currentContext == .join && options.joinCondition == .newLine {
            breakLine()
            linePad = base.adding(levels: 1)
            output += render(linePad) + kw
            afterNewline = false
        } else {
            appendToken(kw)
        }
    }

    private mutating func handleOrderGroup(kw: String, next: SQLToken?) {
        // `WITHIN GROUP (...)`
        guard let next, next.upperValue == "BY" else {
            appendToken(kw)
            return
        }
        let byKw = options.keywordCase.applied(upper: "BY", original: next.value)
        skipCount = 1
        // Window specs and aggregates keep it inline: `OVER (ORDER BY x)`, `STRING_AGG(a, ',' ORDER BY a)`
        if clauseStack.contains(.windowParen) || isInsideNestedExpression {
            appendToken(kw)
            appendToken(byKw)
            return
        }
        closeLists(atOrDeeperThan: indent)
        inSelectColumns = false
        replaceTop(with: .clause)
        breakLine()
        appendToken(kw)
        appendToken(byKw)
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
        if let next, next.upperValue == "ALL" || next.upperValue == "DISTINCT" {
            line += " " + options.keywordCase.applied(upper: next.upperValue, original: next.value)
            skipCount = 1
        }

        if clauseStack.contains(where: Self.isBlockContext) {
            output += (afterNewline ? "" : "\n") + indentStr() + line + "\n"
        } else {
            output += (afterNewline ? "\n" : "\n\n") + line + "\n\n"
        }
        afterNewline = true
        linePad = base
    }

    private mutating func handleCase(kw: String) {
        casePads.append(linePad)
        appendToken(kw)
        clauseStack.append(.caseExpr)
    }

    private mutating func handleWhenElse(kw: String) {
        let whenPad = (casePads.last ?? base).adding(levels: 1)
        linePad = whenPad
        output += (afterNewline ? "" : "\n") + render(whenPad) + kw
        afterNewline = false
    }

    private mutating func handleEnd(kw: String) {
        guard clauseStack.last == .caseExpr else {
            // `END` of a `BEGIN` block, `END IF`, `END LOOP`
            breakLine()
            appendToken(kw)
            return
        }
        clauseStack.removeLast()
        let casePad = casePads.popLast() ?? base
        linePad = casePad
        output += (afterNewline ? "" : "\n") + render(casePad) + kw
        afterNewline = false
    }

    private mutating func handleWith(kw: String, prev: SQLToken?) {
        // `TIMESTAMP WITH TIME ZONE` in a column list or a cast is a type, not a CTE.
        let lineStart = output.count + (afterNewline ? 0 : 1)
        guard startStatement(kw: kw, prev: prev) else { return }
        clauseStack.append(.with)
        if options.clauseItems == .newLine {
            openLists.append(PendingList(kind: .cte, depth: indent, lineStart: lineStart))
            linePad = base.adding(levels: 1)
            pendingLead = (.cte, linePad)
        }
    }

    private mutating func handleInsert(kw: String, prev: SQLToken?, next: SQLToken?) {
        guard startStatement(kw: kw, prev: prev) else { return }
        if let next, next.upperValue == "INTO" {
            output += " " + options.keywordCase.applied(upper: "INTO", original: next.value)
            skipCount = 1
        }
        clauseStack.append(.insert)
    }

    private mutating func handleStatementStart(kw: String, prev: SQLToken?, context: ClauseContext?) {
        guard startStatement(kw: kw, prev: prev) else { return }
        if let context { clauseStack.append(context) }
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
        let items = list.separators.count - (list.hasLead ? 1 : 0)
        if items == 0, !output.containsNewline(in: list.lineStart..<end) { return }
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
        gluePosition = nil
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

    // Open blocks, which is what a list is keyed by.
    private var indent: Int {
        clauseStack.reduce(into: 0) { depth, ctx in
            if Self.isBlockContext(ctx) { depth += 1 }
        }
    }

    // Where a clause of the innermost block starts: one level under the line its `(` is on.
    private var base: Pad {
        blockOpeners.last.map { $0.adding(levels: 1) } ?? Pad(levels: 0)
    }

    private mutating func replaceTop(with ctx: ClauseContext) {
        if !clauseStack.isEmpty { clauseStack.removeLast() }
        clauseStack.append(ctx)
    }

    private func render(_ pad: Pad) -> String {
        String(repeating: indentUnit, count: max(pad.levels, 0)) + String(repeating: " ", count: max(pad.spaces, 0))
    }

    private func indentStr() -> String {
        render(base)
    }

    private mutating func newline() {
        output += "\n"
        afterNewline = true
        linePad = base
    }

    private mutating func breakLine() {
        if afterNewline {
            linePad = base
        } else {
            newline()
        }
    }

    // Written with no space before it: a closing paren, a comma, a call's paren.
    private mutating func writeGlued(_ value: String) {
        output += afterNewline ? indentStr() + value : value
        afterNewline = false
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
        gluePosition = nil
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
