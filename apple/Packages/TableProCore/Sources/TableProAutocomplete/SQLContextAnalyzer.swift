import Foundation
import os
import TableProSQLGrammar

private let regexLogger = Logger(subsystem: "com.TablePro", category: "SQLContextAnalyzer.Regex")

private func compileRegex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
    if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
        return regex
    }
    regexLogger.fault("Failed to compile static regex pattern: \(pattern, privacy: .public)")
    return NSRegularExpression()
}

public enum SQLClauseType: Sendable {
    case select
    case from
    case join
    case on
    case where_
    case and
    case groupBy
    case orderBy
    case having
    case set
    case into
    case values
    case insertColumns
    case functionArg
    case caseExpression
    case inList
    case limit
    case alterTable
    case alterTableColumn
    case createTable
    case columnDef
    case returning
    case union
    case using
    case window
    case dropObject
    case createIndex
    case createView
    case castTarget
    case unknown
}

public struct TableReference: Hashable, Sendable {
    public let tableName: String
    public let alias: String?
    public let schema: String?
    // A subquery or CTE carries the columns of its own SELECT list instead of reading the schema.
    public let derivedColumns: [String]?
    // Whether `identifier` was quoted in the statement, since a qualifier inserted bare would fold to another name.
    public let isIdentifierQuoted: Bool
    // Set while a `*` in the derived table still needs the catalog; the provider resolves it into `derivedColumns`.
    let derivedProjection: DerivedProjection?

    public init(
        tableName: String,
        alias: String?,
        schema: String? = nil,
        derivedColumns: [String]? = nil,
        isIdentifierQuoted: Bool = false
    ) {
        self.tableName = tableName
        self.alias = alias
        self.schema = schema
        self.derivedColumns = derivedColumns
        self.isIdentifierQuoted = isIdentifierQuoted
        self.derivedProjection = nil
    }

    init(tableName: String, alias: String?, schema: String?, projection: DerivedProjection, isIdentifierQuoted: Bool) {
        self.tableName = tableName
        self.alias = alias
        self.schema = schema
        self.derivedColumns = projection.columns { _ in nil }
        self.isIdentifierQuoted = isIdentifierQuoted
        self.derivedProjection = projection.tables.isEmpty ? nil : projection
    }

    func resolvingDerivedColumns(_ columns: [String]) -> TableReference {
        TableReference(
            tableName: tableName,
            alias: alias,
            schema: schema,
            derivedColumns: columns,
            isIdentifierQuoted: isIdentifierQuoted
        )
    }

    public var identifier: String {
        alias ?? tableName
    }

    public var isDerived: Bool {
        derivedColumns != nil
    }
}

// The quoted name the cursor is in, as offsets like `prefixRange`: its opening quote, and its closing quote when the
// name has one of its own.
public struct SQLQuotedName: Sendable, Equatable {
    public let open: Int
    public let close: Int?

    public init(open: Int, close: Int?) {
        self.open = open
        self.close = close
    }
}

public struct SQLContext: Sendable {
    public let clauseType: SQLClauseType
    public let prefix: String
    public private(set) var prefixRange: Range<Int>     // UTF-16 offsets into the analyzed text
    public let dotPrefix: String?          // "u" in "u.name"
    public private(set) var tableReferences: [TableReference]
    public let isInsideString: Bool
    public let isInsideComment: Bool

    public let cteNames: [String]
    public let nestingLevel: Int
    public let currentFunction: String?
    public let isAfterComma: Bool
    public let expectsObjectName: Bool     // The table-operand slot of FROM, JOIN or INTO
    public let comparisonColumn: String?   // The column on the other side of a comparison the cursor is a value in
    public private(set) var quotedName: SQLQuotedName?
    public let outputAliases: [String]     // SELECT-list aliases an ORDER BY at the cursor may name, as written
    public let targetTable: TableReference? // The table the INSERT, UPDATE or MERGE at the cursor writes

    public init(
        clauseType: SQLClauseType,
        prefix: String,
        prefixRange: Range<Int>,
        dotPrefix: String?,
        tableReferences: [TableReference],
        isInsideString: Bool,
        isInsideComment: Bool,
        cteNames: [String] = [],
        nestingLevel: Int = 0,
        currentFunction: String? = nil,
        isAfterComma: Bool = false,
        expectsObjectName: Bool = false,
        comparisonColumn: String? = nil,
        quotedName: SQLQuotedName? = nil,
        outputAliases: [String] = [],
        targetTable: TableReference? = nil
    ) {
        self.clauseType = clauseType
        self.prefix = prefix
        self.prefixRange = prefixRange
        self.dotPrefix = dotPrefix
        self.tableReferences = tableReferences
        self.isInsideString = isInsideString
        self.isInsideComment = isInsideComment
        self.cteNames = cteNames
        self.nestingLevel = nestingLevel
        self.currentFunction = currentFunction
        self.isAfterComma = isAfterComma
        self.expectsObjectName = expectsObjectName
        self.comparisonColumn = comparisonColumn
        self.quotedName = quotedName
        self.outputAliases = outputAliases
        self.targetTable = targetTable
    }

    public func replacingTableReferences(_ references: [TableReference]) -> SQLContext {
        var context = self
        context.tableReferences = references
        return context
    }

    // The same context for text that starts `delta` units later, as a window cut from a document does.
    public func offset(by delta: Int) -> SQLContext {
        var context = self
        context.prefixRange = (prefixRange.lowerBound + delta)..<(prefixRange.upperBound + delta)
        context.quotedName = quotedName.map { SQLQuotedName(open: $0.open + delta, close: $0.close.map { $0 + delta }) }
        return context
    }

    // Ranks the statement-start keywords a popup seeds itself with before the first analysis answers.
    public static let unanalyzed = SQLContext(
        clauseType: .unknown,
        prefix: "",
        prefixRange: 0..<0,
        dotPrefix: nil,
        tableReferences: [],
        isInsideString: false,
        isInsideComment: false
    )
}

public final class SQLContextAnalyzer {
    private static let newline = UInt16(UnicodeScalar("\n").value)
    private static let openParen = UInt16(UnicodeScalar("(").value)
    private static let closeParen = UInt16(UnicodeScalar(")").value)
    private static let dot = UInt16(UnicodeScalar(".").value)
    private static let comma = UInt16(UnicodeScalar(",").value)
    private static let space = UInt16(UnicodeScalar(" ").value)
    private static let tab = UInt16(UnicodeScalar("\t").value)
    private static let cr = UInt16(UnicodeScalar("\r").value)
    private static let colon = UInt16(UnicodeScalar(":").value)
    private static let underscore = UInt16(UnicodeScalar("_").value)
    private static let doubleQuote = UInt16(UnicodeScalar("\"").value)
    private static let backtick = UInt16(UnicodeScalar("`").value)
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let dollar = UInt16(UnicodeScalar("$").value)
    private static let hash = UInt16(UnicodeScalar("#").value)

    // The linear DML clauses are left to `scanLinearClause`: a fixed-priority sweep cannot tell the clause nearest the
    // cursor from an earlier one. Order matters here, the more specific pattern first.
    private static let structuralClauseRegexes: [(regex: NSRegularExpression, clause: SQLClauseType)] = {
        let insertTarget = "\(quotedSegment)(?:\\.\(quotedSegment))*(?:\\s+AS\\s+\(quotedSegment))?"
        let patterns: [(String, SQLClauseType)] = [
            ("\\bADD\\s+(?:COLUMN\\s+)?[`\"']?\\w+[`\"']?\\s+\\w+.*?\\b(?:AFTER|BEFORE)(?:\\s+\\w*)?$",
             .alterTableColumn),
            ("\\b(?:AFTER|BEFORE)(?:\\s+\\w*)?$", .alterTableColumn),
            ("\\bFIRST\\s*$", .alterTable),
            ("\\bALTER\\s+TABLE\\s+[`\"']?\\w+[`\"']?\\s+ADD\\s+CONSTRAINT\\s+\\w*$", .alterTable),
            ("\\bALTER\\s+TABLE\\s+[`\"']?\\w+[`\"']?\\s+ADD\\s+\\w*$", .alterTable),
            (
                "\\b(?:ADD|MODIFY|CHANGE)\\s+(?:COLUMN\\s+)?[`\"']?\\w+[`\"']?\\s+\\w+(?:\\([^)]*\\))?" +
                "(?:\\s+(?:NOT\\s+)?NULL|\\s+DEFAULT(?:\\s+[^\\s]+)?|\\s+AUTO_INCREMENT" +
                "|\\s+UNSIGNED|\\s+COMMENT(?:\\s+'[^']*')?)*\\s*$",
                .columnDef
            ),
            ("\\b(?:ADD|MODIFY|CHANGE)\\s+COLUMN\\s+\\w+\\s*$", .columnDef),
            ("\\bALTER\\s+TABLE\\s+[`\"']?\\w+[`\"']?\\s+(?:DROP|MODIFY|CHANGE|RENAME)" +
             "\\s++(?:COLUMN\\s++)?[`\"']?\\w*[`\"']?\\s*$", .alterTableColumn),
            ("\\bALTER\\s+TABLE\\s+[`\"']?\\w+[`\"']?\\s+\\w*$", .alterTable),
            ("\\bCREATE\\s+TABLE\\s++[^(]*\\([^)]*$", .createTable),
            ("\\bCREATE\\s+(?:TEMPORARY\\s+)?TABLE\\s++[^;]*\\([^)]*\\)\\s*\\w*$", .createTable),
            ("\\bCREATE\\s+(?:TEMPORARY\\s+)?TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?\\w*$", .createTable),
            ("\\bDROP\\s+(?:TABLE|VIEW|INDEX)\\s+(?:IF\\s+EXISTS\\s+)?\\w*$", .dropObject),
            ("\\bCREATE\\s+(?:UNIQUE\\s+)?INDEX\\s+\\w+\\s+ON\\s+\\w+\\s*\\([^)]*$", .createIndex),
            ("\\bCREATE\\s+(?:UNIQUE\\s+)?INDEX\\s+\\w*$", .createIndex),
            ("\\bCREATE\\s+(?:OR\\s+REPLACE\\s+)?(?:MATERIALIZED\\s+)?VIEW\\s+\\w+\\s+AS\\s++[^;]*$",
             .createView),
            ("\\bCREATE\\s+(?:OR\\s+REPLACE\\s+)?(?:MATERIALIZED\\s+)?VIEW\\s+\\w*$", .createView),
            ("\\bUSING\\s*\\([^)]*$", .using),
            ("\\bOVER\\s*\\([^)]*$", .window),
            ("\\bPARTITION\\s+BY\\s++[^)]*$", .window),
            ("\\bIN\\s*\\([^)]*$", .inList),
            ("\\b(LIMIT|OFFSET)\\s+\\d*$", .limit),
            ("\\bVALUES\\s*(?:\\([^)]*\\)\\s*+(?:,\\s*+)?)+\\w*$", .values),
            ("\\bVALUES\\s*\\([^)]*$", .values),
            ("\\bINSERT\\s+INTO\\s+\(insertTarget)\\s*\\([^)]*$", .insertColumns),
        ]
        return patterns.map { pattern, clause in
            (compileRegex(pattern, options: .caseInsensitive), clause)
        }
    }()

    // Read on the code view, where a quoted name's content is masked to word characters, so a segment may be quoted
    // and hold any character.
    private static let quotedSegment = "[`\"'\\[]?\\w+[`\"'\\]]?"

    private static let tableRefRegexes: [NSRegularExpression] = {
        let path = "(\(quotedSegment)(?:\\.\(quotedSegment))*)"
        let alias = "(?:\\s+(?:AS\\s+)?(\(quotedSegment)))?"
        let patterns = [
            // MySQL's STRAIGHT_JOIN has no word boundary before JOIN.
            "(?i)\\b(?:STRAIGHT_)?JOIN\\s+\(path)\(alias)",
            "(?i)\\bUPDATE\\s+\(path)\(alias)",
            "(?i)\\bINSERT\\s+INTO\\s+\(path)",
            "(?i)\\bCREATE\\s+(?:UNIQUE\\s+)?INDEX\\s+\\w+\\s+ON\\s+\(path)"
        ]
        return patterns.map { compileRegex($0) }
    }()

    // Every comma-separated entry up to the next clause keyword, so `FROM a, b, c` puts each table in scope.
    private static let fromListRegex = compileRegex(
        "(?i)\\bFROM\\s+([\\s\\S]+?)" +
        "(?=\\b(?:WHERE|GROUP|ORDER|HAVING|LIMIT|OFFSET|JOIN|INNER|LEFT|RIGHT" +
        "|FULL|CROSS|NATURAL|ON|USING|UNION|INTERSECT|EXCEPT|RETURNING|SET" +
        "|WINDOW|FETCH|FOR)\\b|[;()]|$)"
    )

    private static let alterTableRegex = compileRegex(
        "(?i)\\bALTER\\s+TABLE\\s+(\(quotedSegment)(?:\\.\(quotedSegment))*)"
    )

    private static let derivedTableParser = DerivedTableParser()

    private static func isWhitespace(_ ch: UInt16) -> Bool {
        ch == space || ch == tab || ch == newline || ch == cr
    }

    public init() {}

    // `analyze` reads no tables when its cursor sits in a comment or literal; this reads them wherever the statement
    // ends, so `SELECT * FROM orders -- note` still names `orders`. A CTE's name comes back like a table's, since a
    // CTE can share a table's name and still read that table in its own body.
    public func tableReferences(in statement: String, grammar: SQLLexicalGrammar) -> [TableReference] {
        let nsStatement = statement as NSString
        let text = Self.lex(nsStatement, cursor: nsStatement.length, grammar: grammar)
        var references = extractTableReferences(from: text.forReferences)
        if let alterRef = extractAlterTableReference(from: text.forReferences), !references.contains(alterRef) {
            references.append(alterRef)
        }
        return references
    }

    // MARK: - Main Analysis

    public func analyze(query: String, cursorPosition: Int, grammar: SQLLexicalGrammar) -> SQLContext {
        let nsQuery = query as NSString
        let safePosition = min(cursorPosition, nsQuery.length)

        let located = SQLStatementScanner.locatedStatementAtCursor(
            in: query, cursorPosition: safePosition, grammar: grammar
        )
        let statementOffset = located.offset
        let nsStatement = located.sql as NSString
        let cursor = max(0, min(safePosition - statementOffset, nsStatement.length))
        let text = Self.lex(nsStatement, cursor: cursor, grammar: grammar)

        switch text.cursor {
        case .literal, .comment:
            return SQLContext(
                clauseType: .unknown,
                prefix: "",
                prefixRange: safePosition..<safePosition,
                dotPrefix: nil,
                tableReferences: [],
                isInsideString: text.cursor == .literal,
                isInsideComment: text.cursor == .comment
            )
        case .code, .quotedIdentifier:
            break
        }

        let (prefix, prefixStart, dotPrefix) = extractPrefix(in: text, cursor: cursor, grammar: grammar)

        var tableReferences = extractTableReferences(from: text.forReferences)

        let tokens = Self.tokens(of: text, grammar: grammar)
        let derivedTables = Self.derivedTableParser.visibleTables(in: tokens, cursor: cursor)
        let cteNames = derivedTables.filter(\.isCommonTableExpression).map(\.alias)
        mergeDerivedTables(derivedTables, into: &tableReferences)

        var seenReferences = Set<TableReference>(tableReferences)

        if let alterRef = extractAlterTableReference(from: text.forReferences) {
            if seenReferences.insert(alterRef).inserted {
                tableReferences.append(alterRef)
            }
        }

        let nestingLevel = calculateNestingLevel(in: text.code, end: cursor)

        let currentFunction = detectFunctionContext(in: text, end: cursor)

        let isAfterComma = checkIfAfterComma(text.code, end: cursor)

        // The token being typed is what completion filters on, so it never counts as a committed clause keyword, and
        // a cursor inside a quoted name reads its clause from before the opening quote.
        var clauseEnd = prefixStart
        var quotedName: SQLQuotedName?
        if case .quotedIdentifier(let start, let close) = text.cursor {
            clauseEnd = min(clauseEnd, start)
            quotedName = SQLQuotedName(open: statementOffset + start, close: close.map { statementOffset + $0 })
        }
        let textBeforePrefix = text.code.substring(to: clauseEnd)

        let clauseText = nestingLevel > 0
            ? extractInnermostSubqueryText(from: textBeforePrefix)
            : textBeforePrefix

        let resolution = determineClauseType(
            textBeforeCursor: clauseText,
            dotPrefix: dotPrefix,
            currentFunction: currentFunction
        )

        let isCastTarget = endsWithCastOperator(text.code, before: clauseEnd)
        let comparisonColumn = comparisonTarget(in: text, before: clauseEnd)
        let outputAliases = resolution.clause == .orderBy
            ? Self.derivedTableParser.outputAliases(in: tokens, cursor: clauseEnd)
            : []
        let targetTable = resolution.clause == .set || resolution.clause == .insertColumns
            ? Self.derivedTableParser.targetTable(in: tokens, cursor: clauseEnd).map {
                writtenTable($0, among: tableReferences)
            }
            : nil

        return SQLContext(
            clauseType: isCastTarget ? .castTarget : resolution.clause,
            prefix: prefix,
            prefixRange: (statementOffset + prefixStart)..<safePosition,
            dotPrefix: isCastTarget ? nil : dotPrefix,
            tableReferences: tableReferences,
            isInsideString: false,
            isInsideComment: false,
            cteNames: cteNames,
            nestingLevel: nestingLevel,
            currentFunction: currentFunction,
            isAfterComma: isAfterComma,
            expectsObjectName: resolution.expectsObjectName,
            comparisonColumn: comparisonColumn,
            quotedName: quotedName,
            outputAliases: outputAliases,
            targetTable: targetTable
        )
    }

    // MARK: - Lexing

    static func tokens(of text: LexedStatement, grammar: SQLLexicalGrammar) -> SQLTokenStream {
        let references = text.forReferences
        return SQLTokenStream(
            code: references.code,
            original: references.original,
            bracketQuotes: grammar.contains(.bracketQuotedIdentifiers)
        )
    }

    enum CursorState: Equatable {
        case code
        case comment
        case literal
        case quotedIdentifier(start: Int, close: Int?)
    }

    // `code` blanks every comment and literal body and masks every quoted name's content to `_`, offsets kept, so a
    // scan or pattern reads structure from it and a name from `original` at the same range.
    struct LexedStatement {
        let original: NSString
        let code: NSString
        let cursor: CursorState
        let quotedIdentifierStarts: [Int: Int]
        // `code` with each closed `"` literal masked as a name: ClickHouse and DynamoDB quote names with `"` under a
        // grammar that reads it as a string, and their references were read from such names before.
        let referenceCode: NSString

        var codeString: String { code as String }

        var forReferences: LexedStatement {
            LexedStatement(
                original: original,
                code: referenceCode,
                cursor: cursor,
                quotedIdentifierStarts: quotedIdentifierStarts,
                referenceCode: referenceCode
            )
        }
    }

    static func lex(_ statement: NSString, cursor: Int, grammar: SQLLexicalGrammar) -> LexedStatement {
        let length = statement.length
        var units = [UInt16](repeating: 0, count: length)
        statement.getCharacters(&units, range: NSRange(location: 0, length: length))

        let masksDollarAndHash = grammar.contains(.dollarAndHashInIdentifiers)
        var state = CursorState.code
        var quotedIdentifierStarts: [Int: Int] = [:]
        var doubleQuotedLiterals: [Range<Int>] = []
        var cursorName: SQLNonCodeSpan.Span?
        var openQuoteAtEnd: UInt16?
        var index = 0

        while index < length {
            guard let span = SQLNonCodeSpan.span(at: index, in: statement, grammar: grammar),
                  span.kind != .executableComment else {
                if masksDollarAndHash, index > 0, units[index] == dollar || units[index] == hash,
                   SQLNonCodeSpan.isWordUnit(units[index - 1]) {
                    units[index] = underscore
                }
                index += 1
                continue
            }

            let isIdentifier = isQuotedIdentifier(span, in: statement, grammar: grammar)
            if holds(span, cursor: cursor) {
                if span.kind.isComment {
                    state = .comment
                } else if isIdentifier {
                    state = .quotedIdentifier(start: span.start, close: nil)
                    cursorName = span
                } else {
                    state = .literal
                }
            }
            if !span.isTerminated, span.kind == .quoted {
                openQuoteAtEnd = statement.character(at: span.start)
            }

            if isIdentifier {
                for offset in (span.start + 1)..<max(span.start + 1, span.contentEnd) {
                    units[offset] = underscore
                }
                if span.isTerminated {
                    quotedIdentifierStarts[span.end] = span.start
                }
            } else if span.kind.isComment {
                blank(&units, span.start..<span.end)
            } else {
                // A literal keeps its delimiters, so `= 'x' |` still reads as past the value.
                let contentEnd = span.isTerminated ? span.end - 1 : span.end
                blank(&units, (span.start + 1)..<max(span.start + 1, contentEnd))
                if span.isTerminated, span.kind == .quoted, statement.character(at: span.start) == doubleQuote {
                    doubleQuotedLiterals.append((span.start + 1)..<max(span.start + 1, contentEnd))
                }
            }
            index = max(span.end, index + 1)
        }

        if let name = cursorName, name.isTerminated,
           closeBelongsToName(name, in: statement, openQuoteAtEnd: openQuoteAtEnd) {
            state = .quotedIdentifier(start: name.start, close: name.end - 1)
        }

        let code = makeString(units)
        var referenceCode = code
        if !doubleQuotedLiterals.isEmpty {
            for range in doubleQuotedLiterals {
                for offset in range {
                    units[offset] = underscore
                }
            }
            referenceCode = makeString(units)
        }
        return LexedStatement(
            original: statement,
            code: code,
            cursor: state,
            quotedIdentifierStarts: quotedIdentifierStarts,
            referenceCode: referenceCode
        )
    }

    // The lexer pairs a typed quote with the next one, which may open a later name, as in `"Ord| WHERE "id" = 1`. The
    // close is the name's only while the rest of the statement still balances, and brackets do not nest.
    private static func closeBelongsToName(
        _ name: SQLNonCodeSpan.Span,
        in statement: NSString,
        openQuoteAtEnd: UInt16?
    ) -> Bool {
        let opener = statement.character(at: name.start)
        guard openQuoteAtEnd != opener else { return false }
        guard opener == openBracket else { return true }
        return !((name.start + 1)..<(name.end - 1)).contains { statement.character(at: $0) == openBracket }
    }

    private static func makeString(_ units: [UInt16]) -> NSString {
        units.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { NSString(characters: $0, length: units.count) } ?? NSString()
        }
    }

    private static func blank(_ units: inout [UInt16], _ range: Range<Int>) {
        for offset in range where units[offset] != newline {
            units[offset] = space
        }
    }

    static func holds(_ span: SQLNonCodeSpan.Span, cursor: Int) -> Bool {
        guard cursor > span.start else { return false }
        if !span.isTerminated || span.kind == .lineComment {
            return cursor <= span.end
        }
        return cursor < span.end
    }

    static func isQuotedIdentifier(
        _ span: SQLNonCodeSpan.Span,
        in text: NSString,
        grammar: SQLLexicalGrammar
    ) -> Bool {
        guard span.kind == .quoted else { return false }
        switch text.character(at: span.start) {
        case backtick, openBracket:
            return true
        case doubleQuote:
            // Stands in for "a double quote opens a string": ClickHouse and DynamoDB set it too, with `"` an identifier.
            return !grammar.contains(.backslashEscapesInDoubleQuotes)
        default:
            return false
        }
    }

    // MARK: - Subquery Support

    private func calculateNestingLevel(in code: NSString, end: Int) -> Int {
        var level = 0
        for index in 0..<end {
            let ch = code.character(at: index)
            if ch == Self.openParen {
                level += 1
            } else if ch == Self.closeParen {
                level = max(0, level - 1)
            }
        }
        return level
    }

    private static let subqueryDetectRegex = compileRegex(
        "^\\s*(?:SELECT|INSERT|UPDATE|DELETE)\\b",
        options: .caseInsensitive
    )

    // Only a parenthesis a statement keyword follows opens a subquery, so `INSERT INTO t (a, b` and `USING (id` keep
    // the outer clause.
    private func extractInnermostSubqueryText(from textBeforeCursor: String) -> String {
        let ns = textBeforeCursor as NSString
        let length = ns.length
        var parenStack: [Int] = []

        for i in 0..<length {
            let ch = ns.character(at: i)
            if ch == Self.openParen {
                parenStack.append(i)
            } else if ch == Self.closeParen, !parenStack.isEmpty {
                parenStack.removeLast()
            }
        }

        for openPos in parenStack.reversed() {
            let start = openPos + 1
            if start < length {
                let subText = ns.substring(from: start)
                let matchRange = NSRange(location: 0, length: (subText as NSString).length)
                if Self.subqueryDetectRegex.firstMatch(in: subText, range: matchRange) != nil {
                    return subText
                }
            }
        }

        return textBeforeCursor
    }

    // MARK: - Function Context

    private static let subqueryKeywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "IN", "EXISTS", "NOT"
    ]

    private func detectFunctionContext(in text: LexedStatement, end: Int) -> String? {
        var parenStack: [String?] = []
        var wordStart = -1
        var lastWord: String?

        for i in 0..<end {
            let ch = text.code.character(at: i)
            if SQLTokenBoundary.isIdentifierChar(ch) {
                if wordStart < 0 {
                    wordStart = i
                }
                continue
            }
            if wordStart >= 0 {
                lastWord = text.original.substring(with: NSRange(location: wordStart, length: i - wordStart))
                wordStart = -1
            }
            if ch == Self.openParen {
                parenStack.append(lastWord)
                lastWord = nil
            } else if ch == Self.closeParen, !parenStack.isEmpty {
                parenStack.removeLast()
            }
        }

        guard let precedingWord = parenStack.last, let funcName = precedingWord,
              !Self.subqueryKeywords.contains(funcName.uppercased()) else { return nil }
        return funcName
    }

    // MARK: - Comma Detection

    private func checkIfAfterComma(_ code: NSString, end: Int) -> Bool {
        var i = end - 1
        while i >= 0 {
            let ch = code.character(at: i)
            if Self.isWhitespace(ch) {
                i -= 1
                continue
            }
            return ch == Self.comma
        }
        return false
    }

    // MARK: - Comparison

    private func comparisonTarget(in text: LexedStatement, before prefixStart: Int) -> String? {
        let code = text.code
        var index = skippingWhitespaceBackwards(in: code, from: min(prefixStart, code.length))
        guard let operatorStart = comparisonOperatorStart(in: code, endingAt: index) else { return nil }

        index = skippingWhitespaceBackwards(in: code, from: operatorStart)
        let identifierEnd = index
        while index > 0, SQLTokenBoundary.isIdentifierChar(code.character(at: index - 1)) {
            index -= 1
        }
        guard index < identifierEnd else { return nil }

        let identifier = text.original.substring(with: NSRange(location: index, length: identifierEnd - index))
        guard !Self.comparisonStopWords.contains(identifier.uppercased()) else { return nil }
        return identifier
    }

    private func skippingWhitespaceBackwards(in text: NSString, from start: Int) -> Int {
        var index = start
        while index > 0, Self.isWhitespace(text.character(at: index - 1)) {
            index -= 1
        }
        return index
    }

    private func comparisonOperatorStart(in text: NSString, endingAt end: Int) -> Int? {
        for symbol in Self.comparisonOperators {
            let length = (symbol as NSString).length
            guard end >= length else { continue }
            let range = NSRange(location: end - length, length: length)
            guard text.substring(with: range).caseInsensitiveCompare(symbol) == .orderedSame else { continue }

            let start = end - length
            let isWordOperator = symbol.first?.isLetter == true
            if isWordOperator, start > 0, SQLTokenBoundary.isIdentifierChar(text.character(at: start - 1)) {
                continue
            }
            return start
        }
        return nil
    }

    private static let comparisonOperators: [String] = ["<>", "!=", "<=", ">=", "=", "<", ">", "IN", "LIKE", "ILIKE"]

    private static let comparisonStopWords: Set<String> = [
        "AND", "OR", "NOT", "WHERE", "ON", "HAVING", "SELECT", "SET", "WHEN", "THEN", "ELSE", "BY"
    ]

    private func endsWithCastOperator(_ text: NSString, before prefixStart: Int) -> Bool {
        guard prefixStart >= 2, prefixStart <= text.length else { return false }
        return text.character(at: prefixStart - 1) == Self.colon && text.character(at: prefixStart - 2) == Self.colon
    }

    // MARK: - Prefix

    private func extractPrefix(
        in text: LexedStatement,
        cursor: Int,
        grammar: SQLLexicalGrammar
    ) -> (prefix: String, start: Int, dotPrefix: String?) {
        let ns = text.original
        let start: Int
        let tokenStart: Int
        if case .quotedIdentifier(let open, let close) = text.cursor {
            // A quoted name may hold spaces, so the whole name is the prefix; an open one's range keeps its quote.
            start = close == nil ? open : open + 1
            tokenStart = open
        } else {
            let segment = SQLTokenBoundary.segment(in: ns, endingAt: cursor, grammar: grammar)
            start = segment.start
            tokenStart = segment.openQuote ?? start
        }
        let prefix = SQLTokenBoundary.matchText(of: ns.substring(with: NSRange(location: start, length: cursor - start)))

        guard tokenStart > 0, ns.character(at: tokenStart - 1) == Self.dot else {
            return (prefix, start, nil)
        }
        let qualifierEnd = tokenStart - 1

        if let quotedStart = text.quotedIdentifierStarts[qualifierEnd] {
            let raw = ns.substring(with: NSRange(location: quotedStart, length: qualifierEnd - quotedStart))
            return (prefix, start, Self.unquoted(raw))
        }

        let qualifierStart = SQLTokenBoundary.segmentStart(in: ns, endingAt: qualifierEnd, grammar: grammar)
        guard qualifierStart < qualifierEnd else {
            return (prefix, start, nil)
        }

        let qualifierRange = NSRange(location: qualifierStart, length: qualifierEnd - qualifierStart)
        let dotPrefix = SQLTokenBoundary.matchText(of: ns.substring(with: qualifierRange))
        return (prefix, start, dotPrefix)
    }

    // MARK: - Table References

    private static let tableRefKeywords: Set<String> = [
        "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "NATURAL",
        "JOIN", "ON", "AND", "OR", "WHERE", "SELECT", "FROM", "AS", "SET", "LATERAL"
    ]

    private static let bareIdentifierRegex = compileRegex("^\\w+$")

    private static func isBareIdentifier(_ value: String) -> Bool {
        let range = NSRange(location: 0, length: (value as NSString).length)
        return bareIdentifierRegex.firstMatch(in: value, range: range) != nil
    }

    private static let identifierQuoteChars = CharacterSet(charactersIn: "`\"'[]")

    private static func closingQuote(for character: Character) -> Character? {
        switch character {
        case "\"", "`", "'":
            return character
        case "[":
            return "]"
        default:
            return nil
        }
    }

    private static func isQuoted(_ raw: String) -> Bool {
        raw.first.flatMap(closingQuote(for:)) != nil
    }

    private static func unquoted(_ raw: String) -> String {
        guard let first = raw.first, let close = closingQuote(for: first) else {
            return raw.trimmingCharacters(in: identifierQuoteChars)
        }
        var body = raw.dropFirst()
        if body.last == close {
            body = body.dropLast()
        }
        let closer = String(close)
        return String(body).replacingOccurrences(of: closer + closer, with: closer)
    }

    // A quoted alias is a name whatever it spells; a bare keyword is the next clause.
    private static func aliasName(_ raw: String) -> String? {
        let name = unquoted(raw)
        guard !name.isEmpty else { return nil }
        guard isQuoted(raw) || !tableRefKeywords.contains(name.uppercased()) else { return nil }
        return name
    }

    private struct PathSegment {
        let masked: String
        let name: String
        let isQuoted: Bool
    }

    private static func pathSegments(_ range: NSRange, in text: LexedStatement) -> [PathSegment] {
        var segments: [PathSegment] = []
        var start = range.location
        let end = range.location + range.length

        func append(upTo stop: Int) {
            guard stop > start else { return }
            let piece = NSRange(location: start, length: stop - start)
            let raw = text.original.substring(with: piece)
            segments.append(PathSegment(masked: text.code.substring(with: piece), name: unquoted(raw), isQuoted: isQuoted(raw)))
        }

        for index in range.location..<end where text.code.character(at: index) == dot {
            append(upTo: index)
            start = index + 1
        }
        append(upTo: end)
        return segments
    }

    private static func ranges(in range: NSRange, of code: NSString, splitBy isSeparator: (UInt16) -> Bool) -> [NSRange] {
        var pieces: [NSRange] = []
        var start = range.location
        let end = range.location + range.length
        for index in range.location..<end where isSeparator(code.character(at: index)) {
            if index > start {
                pieces.append(NSRange(location: start, length: index - start))
            }
            start = index + 1
        }
        if end > start {
            pieces.append(NSRange(location: start, length: end - start))
        }
        return pieces
    }

    private func extractTableReferences(from text: LexedStatement) -> [TableReference] {
        var references: [TableReference] = []
        var seen = Set<TableReference>()

        appendFromListReferences(from: text, into: &references, seen: &seen)

        let nsRange = NSRange(location: 0, length: text.code.length)

        for regex in Self.tableRefRegexes {
            regex.enumerateMatches(in: text.codeString, range: nsRange) { match, _, _ in
                guard let match = match else { return }

                let pathRange = match.range(at: 1)
                guard pathRange.location != NSNotFound else { return }

                let segments = Self.pathSegments(pathRange, in: text)
                guard let table = segments.last, !table.name.isEmpty else { return }
                guard table.isQuoted || !Self.tableRefKeywords.contains(table.name.uppercased()) else { return }

                let schema = segments.count >= 2 ? segments[segments.count - 2].name : nil

                var alias: String?
                var isAliasQuoted = false
                if match.numberOfRanges > 2 {
                    let aliasNSRange = match.range(at: 2)
                    if aliasNSRange.location != NSNotFound {
                        let raw = text.original.substring(with: aliasNSRange)
                        alias = Self.aliasName(raw)
                        isAliasQuoted = Self.isQuoted(raw)
                    }
                }

                let ref = TableReference(
                    tableName: table.name,
                    alias: alias,
                    schema: schema,
                    isIdentifierQuoted: alias == nil ? table.isQuoted : isAliasQuoted
                )
                if seen.insert(ref).inserted {
                    references.append(ref)
                }
            }
        }

        return references
    }

    // Columns attach to a matching reference, such as a CTE aliased in FROM, and the derived table or CTE is still
    // registered under its own name so it resolves by either identifier.
    // SQL Server writes `UPDATE o SET ... FROM orders o`, naming the table by its FROM alias.
    private func writtenTable(_ target: TableReference, among references: [TableReference]) -> TableReference {
        guard target.schema == nil, let aliased = references.first(where: {
            !$0.isDerived && $0.alias?.caseInsensitiveCompare(target.tableName) == .orderedSame
        }) else { return target }
        return aliased
    }

    private func mergeDerivedTables(_ derivedTables: [DerivedTable], into references: inout [TableReference]) {
        let projectionsByAlias = Dictionary(
            derivedTables.map { ($0.alias.lowercased(), $0.projection) },
            uniquingKeysWith: { first, _ in first }
        )

        for index in references.indices {
            let ref = references[index]
            // A schema-qualified name is a real table even when a CTE shares its name.
            guard ref.schema == nil else { continue }
            for key in [ref.tableName.lowercased(), ref.identifier.lowercased()] {
                guard let projection = projectionsByAlias[key] else { continue }
                references[index] = TableReference(
                    tableName: ref.tableName,
                    alias: ref.alias,
                    schema: nil,
                    projection: projection,
                    isIdentifierQuoted: ref.isIdentifierQuoted
                )
                break
            }
        }

        var present = Set(references.map { $0.identifier.lowercased() })
        for derived in derivedTables where present.insert(derived.alias.lowercased()).inserted {
            references.append(TableReference(
                tableName: derived.alias,
                alias: derived.alias,
                schema: nil,
                projection: derived.projection,
                isIdentifierQuoted: false
            ))
        }
    }

    private func appendFromListReferences(
        from text: LexedStatement,
        into references: inout [TableReference],
        seen: inout Set<TableReference>
    ) {
        let nsRange = NSRange(location: 0, length: text.code.length)
        Self.fromListRegex.enumerateMatches(in: text.codeString, range: nsRange) { match, _, _ in
            guard let match = match else { return }
            let listRange = match.range(at: 1)
            guard listRange.location != NSNotFound else { return }

            for entry in Self.ranges(in: listRange, of: text.code, splitBy: { $0 == Self.comma }) {
                guard let ref = self.tableReference(fromListEntry: entry, in: text) else { continue }
                if seen.insert(ref).inserted {
                    references.append(ref)
                }
            }
        }
    }

    private func tableReference(fromListEntry entry: NSRange, in text: LexedStatement) -> TableReference? {
        let tokens = Self.ranges(in: entry, of: text.code, splitBy: Self.isWhitespace)
        guard let pathToken = tokens.first else { return nil }

        let segments = Self.pathSegments(pathToken, in: text)
        guard let table = segments.last, !table.name.isEmpty else { return nil }
        // Only a plain identifier path, so `FROM (SELECT ...) x` never yields a phantom table.
        guard segments.allSatisfy({
            Self.isBareIdentifier($0.masked.trimmingCharacters(in: Self.identifierQuoteChars))
        }) else { return nil }
        guard table.isQuoted || !Self.tableRefKeywords.contains(table.name.uppercased()) else { return nil }

        let schema = segments.count >= 2 ? segments[segments.count - 2].name : nil

        var alias: String?
        var isAliasQuoted = false
        if tokens.count >= 2 {
            var candidate = tokens[1]
            if text.original.substring(with: candidate).uppercased() == "AS", tokens.count >= 3 {
                candidate = tokens[2]
            }
            let raw = text.original.substring(with: candidate)
            alias = Self.aliasName(raw)
            isAliasQuoted = Self.isQuoted(raw)
        }

        return TableReference(
            tableName: table.name,
            alias: alias,
            schema: schema,
            isIdentifierQuoted: alias == nil ? table.isQuoted : isAliasQuoted
        )
    }

    private func extractAlterTableReference(from text: LexedStatement) -> TableReference? {
        let nsRange = NSRange(location: 0, length: text.code.length)
        guard let match = Self.alterTableRegex.firstMatch(in: text.codeString, range: nsRange) else { return nil }
        let pathRange = match.range(at: 1)
        guard pathRange.location != NSNotFound else { return nil }
        let segments = Self.pathSegments(pathRange, in: text)
        guard let table = segments.last, !table.name.isEmpty else { return nil }
        return TableReference(
            tableName: table.name,
            alias: nil,
            schema: segments.count >= 2 ? segments[segments.count - 2].name : nil,
            isIdentifierQuoted: table.isQuoted
        )
    }

    // MARK: - Clause Detection

    private struct ClauseResolution {
        let clause: SQLClauseType
        let expectsObjectName: Bool
    }

    private func determineClauseType(
        textBeforeCursor: String,
        dotPrefix: String?,
        currentFunction: String? = nil
    ) -> ClauseResolution {
        if dotPrefix != nil {
            return ClauseResolution(clause: .select, expectsObjectName: false)
        }

        // Bounds the regex work on a long statement. SQLContextAnalyzerWindowingTests pins the size.
        let windowSize = 5_000
        let nsText = textBeforeCursor as NSString
        let windowedText = nsText.length > windowSize
            ? nsText.substring(from: nsText.length - windowSize)
            : textBeforeCursor

        // Structural contexts first: `CREATE TABLE test (id ` looks like a call to `test(` but is a column definition.
        let range = NSRange(location: 0, length: (windowedText as NSString).length)
        for (regex, clause) in Self.structuralClauseRegexes {
            if regex.firstMatch(in: windowedText, range: range) != nil {
                return ClauseResolution(clause: clause, expectsObjectName: false)
            }
        }

        // The keyword nearest the cursor wins, which is what lets `... ON a = b JOIN |` read JOIN.
        if let resolution = scanLinearClause(in: windowedText) {
            return resolution
        }

        if currentFunction != nil {
            return ClauseResolution(clause: .functionArg, expectsObjectName: false)
        }

        return ClauseResolution(clause: .unknown, expectsObjectName: false)
    }

    // MARK: - Linear Clause Scan

    private enum ScanTokenKind {
        case word
        case openParen
        case closeParen
        case comma
        case other
    }

    private struct ScanToken {
        let kind: ScanTokenKind
        let upper: String
    }

    // Walks backwards, skipping closed parentheses and balanced `CASE ... END`, and passes through an open
    // parenthesis so the clause around a call or grouping is still found.
    private func scanLinearClause(in cleaned: String) -> ClauseResolution? {
        let tokens = tokenize(cleaned)
        var depth = 0
        var pendingEnd = 0
        var sawObject = false
        var slotClosed = false

        for index in stride(from: tokens.count - 1, through: 0, by: -1) {
            let token = tokens[index]
            switch token.kind {
            case .closeParen:
                depth += 1
            case .openParen:
                if depth > 0 { depth -= 1 }
            case .other:
                continue
            case .comma:
                // A comma closes the operand slot, so a later table in `FROM a, b` still expects a name.
                if depth == 0 { slotClosed = true }
            case .word:
                guard depth == 0 else { continue }
                let word = token.upper
                if word == "END" {
                    pendingEnd += 1
                    slotClosed = true
                    continue
                }
                if word == "CASE" {
                    if pendingEnd > 0 {
                        pendingEnd -= 1
                        slotClosed = true
                        continue
                    }
                    return ClauseResolution(clause: .caseExpression, expectsObjectName: false)
                }
                guard pendingEnd == 0 else { continue }
                let previous = index > 0 ? tokens[index - 1].upper : nil
                if let clause = clause(forKeyword: word, previous: previous, sawObject: sawObject) {
                    return clause
                }
                if !slotClosed { sawObject = true }
            }
        }

        return nil
    }

    // `sawObject` means an operand already sits between the keyword and the cursor, so the slot is past.
    private func clause(forKeyword word: String, previous: String?, sawObject: Bool) -> ClauseResolution? {
        switch word {
        case "WHEN", "THEN", "ELSE":
            return ClauseResolution(clause: .caseExpression, expectsObjectName: false)
        case "SELECT":
            return ClauseResolution(clause: .select, expectsObjectName: false)
        case "FROM":
            return ClauseResolution(clause: .from, expectsObjectName: !sawObject)
        case "JOIN":
            return ClauseResolution(clause: .join, expectsObjectName: !sawObject)
        case "INTO":
            return ClauseResolution(clause: .into, expectsObjectName: !sawObject)
        case "ON":
            return ClauseResolution(clause: .on, expectsObjectName: false)
        case "WHERE":
            return ClauseResolution(clause: .where_, expectsObjectName: false)
        case "AND", "OR":
            return ClauseResolution(clause: .and, expectsObjectName: false)
        case "HAVING":
            return ClauseResolution(clause: .having, expectsObjectName: false)
        case "SET":
            return ClauseResolution(clause: .set, expectsObjectName: false)
        case "RETURNING":
            return ClauseResolution(clause: .returning, expectsObjectName: false)
        case "UNION", "INTERSECT", "EXCEPT":
            return ClauseResolution(clause: .union, expectsObjectName: false)
        case "BY":
            switch previous {
            case "GROUP":
                return ClauseResolution(clause: .groupBy, expectsObjectName: false)
            case "ORDER":
                return ClauseResolution(clause: .orderBy, expectsObjectName: false)
            case "PARTITION":
                return ClauseResolution(clause: .window, expectsObjectName: false)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private func tokenize(_ text: String) -> [ScanToken] {
        let ns = text as NSString
        let length = ns.length
        var tokens: [ScanToken] = []
        var wordStart = -1

        func flushWord(end: Int) {
            guard wordStart >= 0 else { return }
            let word = ns.substring(with: NSRange(location: wordStart, length: end - wordStart))
            tokens.append(ScanToken(kind: .word, upper: word.uppercased()))
            wordStart = -1
        }

        for i in 0..<length {
            let ch = ns.character(at: i)
            // Quote marks are token characters, so a quoted identifier is one word that never matches a keyword.
            if SQLTokenBoundary.isTokenChar(ch) {
                if wordStart < 0 { wordStart = i }
                continue
            }
            flushWord(end: i)
            switch ch {
            case Self.openParen:
                tokens.append(ScanToken(kind: .openParen, upper: ""))
            case Self.closeParen:
                tokens.append(ScanToken(kind: .closeParen, upper: ""))
            case Self.comma:
                tokens.append(ScanToken(kind: .comma, upper: ""))
            default:
                if !Self.isWhitespace(ch) {
                    tokens.append(ScanToken(kind: .other, upper: ""))
                }
            }
        }
        flushWord(end: length)

        return tokens
    }
}
