import Foundation

// What a statement reaches past its rows: files, the network, server code, sequences and dynamic SQL.
extension SQLStatementTiering {
    // A comment or a line break between the two words is nothing to the server.
    static let filesystemWordRuns: [[String]] = [
        ["INTO", "OUTFILE"], ["INTO", "DUMPFILE"], ["TO", "PROGRAM"], ["FROM", "PROGRAM"], ["VACUUM", "INTO"],
    ]

    // Procedures and packages, reached by their name with or without a call.
    static let filesystemNames: Set<String> = [
        "XP_CMDSHELL", "SP_OACREATE", "XP_DIRTREE", "XP_FILEEXIST", "XP_SUBDIRS", "XP_REGREAD", "XP_REGWRITE",
        "SP_EXECUTE_EXTERNAL_SCRIPT", "UTL_HTTP", "UTL_FILE", "UTL_TCP", "UTL_SMTP", "UTL_INADDR",
    ]

    static let filesystemFunctions: Set<String> = [
        "LOAD_FILE", "PG_READ_FILE", "PG_READ_BINARY_FILE", "PG_LS_DIR", "SYS_READ_FILE", "SYS_READ_BINARY_FILE",
        "SYS_LS_DIR", "LO_IMPORT", "LO_EXPORT", "PG_FILE_WRITE", "LOAD_EXTENSION", "READFILE", "WRITEFILE",
        "FN_GET_AUDIT_FILE", "OPENROWSET", "OPENDATASOURCE", "FSDIR", "PG_STAT_FILE", "PG_LS_LOGDIR", "PG_LS_WALDIR",
        "PG_LS_TMPDIR", "PG_LS_ARCHIVE_STATUSDIR", "PG_LS_LOGICALSNAPDIR", "PG_LS_LOGICALMAPDIR", "PG_LS_REPLSLOTDIR",
        "PG_FILE_UNLINK", "PG_FILE_RENAME", "PG_FILE_SYNC", "PG_FILE_READ", "PG_LOGDIR_LS",
        "FN_XE_FILE_TARGET_READ_FILE", "FN_TRACE_GETTABLE", "FN_DUMP_DBLOG", "DM_OS_ENUMERATE_FILESYSTEM",
        "DM_OS_FILE_EXISTS", "BFILENAME", "HTTPURITYPE",
    ]

    // Per engine, since `glob` is a scalar on SQLite and `file` and `url` name columns anywhere.
    static let functionsReachingOutside: [String: Set<String>] = [
        duckDB: [
            "GLOB", "SNIFF_CSV", "GETENV", "QUERY", "QUERY_TABLE", "JSON_EXECUTE_SERIALIZED_SQL", "FROM_SUBSTRAIT",
            "FROM_SUBSTRAIT_JSON", "IMPORT_DATABASE", "ARROW_SCAN", "ARROW_SCAN_DUMB", "LOAD_AWS_CREDENTIALS",
            "ENABLE_LOGGING", "START_UI", "START_UI_SERVER"
        ],
        clickHouse: [
            "FILE", "FILECLUSTER", "URL", "URLCLUSTER", "S3", "S3CLUSTER", "GCS", "COSN", "OSS", "HDFS", "HDFSCLUSTER",
            "REMOTE", "REMOTESECURE", "MYSQL", "POSTGRESQL", "MONGODB", "REDIS", "SQLITE", "JDBC", "ODBC", "EXECUTABLE",
            "ARROWFLIGHT", "YTSAURUS"
        ],
        // SurrealQL runs `function() { ... }` as JavaScript on a server with scripting on.
        surrealDB: ["FUNCTION"]
    ]

    static let functionFamiliesReachingOutside: [String: [String]] = [
        duckDB: ["READ_", "PARQUET_", "ST_READ", "ICEBERG_", "DELTA_", "SQLITE_", "POSTGRES_", "MYSQL_"],
        clickHouse: ["AZUREBLOBSTORAGE", "ICEBERG", "DELTALAKE", "HUDI", "PAIMON"]
    ]

    // A read of a file stays a read in the app's own windows, where the tier sets the row cap.
    static let readOutsideDatabase = StatementClassification(tier: .safe, reachesFilesystemOrExecutesCode: true)

    static let period = UInt16(UnicodeScalar(".").value)
    static let colon = UInt16(UnicodeScalar(":").value)

    static func namesFilesystemSurface(_ tokens: [TSQLTokens.Token], in code: NSString) -> Bool {
        tokens.indices.contains { index in
            if let word = tokens[index].word, filesystemNames.contains(word) { return true }
            if tokens[index].kind == .name, filesystemNames.contains(nameText(at: index, in: tokens, code: code)) {
                return true
            }
            return filesystemWordRuns.contains { StatementCode.spells($0, at: index, in: tokens) }
        }
    }

    // A server resolves an object name by its own case folding, under which `utl_ınaddr` and `xp_cmdſhell` may be the
    // packages they spell, so a name with a letter outside ASCII is compared uppercased, as a call's name is. The name
    // ends at the first blank scalar, as the token did, even one that joins the letter before it.
    private static func nameText(at index: Int, in tokens: [TSQLTokens.Token], code: NSString) -> String {
        let start = tokens[index].location
        let end = tokens.indices.contains(index + 1) ? tokens[index + 1].location : code.length
        let span = code.substring(with: NSRange(location: start, length: end - start))
        var name = String.UnicodeScalarView()
        name.append(contentsOf: span.unicodeScalars.prefix { !StatementBlank.isBlank($0) })
        return String(name).uppercased()
    }

    // A callee the scanner cannot name counts as one.
    static func callsFilesystemFunction(_ calls: [SQLFunctionCallScanner.Call]) -> Bool {
        calls.contains { call in
            guard case .named(let name, _) = call.callee else { return true }
            let function = name.uppercased()
            // KingbaseES ships each pg_ function under a sys_ name too.
            let alias = function.hasPrefix("SYS_") ? "PG_" + function.dropFirst(4) : function
            return filesystemFunctions.contains(function) || filesystemFunctions.contains(alias)
        }
    }

    static let identifierQuotes: Set<UInt16> = [
        SqlLexer.doubleQuote, SqlLexer.backtick, UInt16(UnicodeScalar("[").value)
    ]

    // `EXEC [xp_cmdshell] 'dir'` runs the procedure its plain spelling does.
    static func quotesFilesystemProcedure(
        in statement: String,
        grammar: SQLLexicalGrammar,
        revealingExecutableComments: Bool = false
    ) -> Bool {
        let text = statement as NSString
        let length = text.length
        var index = 0
        while index < length {
            if revealingExecutableComments,
               let opener = SqlLexer.executableCommentOpenerLength(text, at: index, length: length) {
                index += opener
                continue
            }
            guard let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) else {
                index += 1
                continue
            }
            if span.kind == .quoted, identifierQuotes.contains(text.character(at: span.start)) {
                let inner = NSRange(location: span.start + 1, length: max(0, span.contentEnd - span.start - 1))
                if filesystemNames.contains(text.substring(with: inner).uppercased()) { return true }
            }
            index = max(span.end, index + 1)
        }
        return false
    }

    func reachesOutsideDatabase(
        _ code: StatementCode,
        calls: [SQLFunctionCallScanner.Call],
        grammar: SQLLexicalGrammar
    ) -> Bool {
        // SurrealQL's http:: functions make requests from the server.
        if databaseTypeId == Self.surrealDB, code.tokens.indices.contains(where: { index in
            code.tokens[index].word == "HTTP" && code.isSymbol(Self.colon, at: index + 1)
                && code.isSymbol(Self.colon, at: index + 2)
        }) {
            return true
        }
        guard let names = Self.functionsReachingOutside[databaseTypeId] else { return false }
        if databaseTypeId == Self.duckDB, SQLFileNamedAsTable.appears(in: code.statement, grammar: grammar) {
            return true
        }
        let families = Self.functionFamiliesReachingOutside[databaseTypeId] ?? []
        return calls.contains { call in
            guard case .named(let name, _) = call.callee else { return true }
            let function = name.uppercased()
            return names.contains(function) || families.contains(where: function.hasPrefix)
        }
    }

    // KingbaseES has it in Oracle mode only, and its type id cannot say which mode a server runs.
    static let enginesWithSequencePseudoColumns: Set<String> = [
        "Oracle", "SAP HANA", "Snowflake", "Dameng", "MariaDB", "KingbaseES",
    ]

    /// `NEXT VALUE FOR seq` (SQL Server, MariaDB, Db2) and `NEXTVAL FOR seq` (Db2) advance a sequence with no call for
    /// the function scanner to see, the way `nextval('seq')` does on PostgreSQL. `seq.NEXTVAL` does the same on the
    /// engines that have the pseudo-column; elsewhere `t.nextval` is a column.
    func advancesSequence(_ code: StatementCode) -> Bool {
        let tokens = code.tokens
        let pseudoColumns = Self.enginesWithSequencePseudoColumns.contains(databaseTypeId)
        return tokens.indices.contains { index in
            if code.spells(["NEXT", "VALUE", "FOR"], at: index) || code.spells(["NEXTVAL", "FOR"], at: index) {
                return true
            }
            return pseudoColumns && tokens[index].word == "NEXTVAL" && code.isSymbol(Self.period, at: index - 1)
        }
    }

    // An EXPLAIN that runs its statement is tiered by that statement's own calls.
    func stateChangingCallTier(
        _ code: StatementCode,
        calls: [SQLFunctionCallScanner.Call],
        grammar: SQLLexicalGrammar
    ) -> StatementTier {
        guard !SQLExplainStatement.keywords.contains(code.keyword) else { return .safe }
        if advancesSequence(code) { return .write }
        let changesState = calls.contains { call in
            guard case .named(let name, _) = call.callee else { return true }
            return SQLStateChangingFunctions.contains(name)
                || (databaseTypeId == Self.duckDB && SQLStateChangingFunctions.isDuckDBCall(name))
        }
        guard !changesState else { return .write }
        let namesTable = SQLStateChangingFunctions.namesStateChangingTable(
            in: code.text, tokens: code.tokens, grammar: grammar
        )
        return namesTable ? .write : .safe
    }

    /// A MySQL `/*! ... */` runs its body, so it is tiered by what the body says whatever the grammar thinks of it, and
    /// a statement holding one is never safe. What a server that skips it runs is tiered as a text of its own.
    static func conditionalCommentClassification(
        _ statement: String,
        grammar: SQLLexicalGrammar
    ) -> StatementClassification? {
        let readsOpeners = grammar.union(.executableComments)
        guard SQLExecutableCommentReadings.holdsExecutableComment(statement, grammar: readsOpeners) else { return nil }
        let revealedCode = SQLCodeProjection.code(
            of: statement, grammar: readsOpeners, revealingExecutableComments: true
        ) as NSString
        let tokens = TSQLTokens.read(code: revealedCode, grammar: readsOpeners)
        let words = Set(tokens.compactMap(\.word))
        let revealedCalls = SQLFunctionCallScanner.calls(in: statement as NSString, code: revealedCode)
        let reachesFilesystemOrExecutesCode = namesFilesystemSurface(tokens, in: revealedCode)
            || callsFilesystemFunction(revealedCalls)
            || quotesFilesystemProcedure(in: statement, grammar: grammar, revealingExecutableComments: true)
            || !words.isDisjoint(with: filesystemOrCodeKeywords)
        return StatementClassification(
            tier: words.isDisjoint(with: dataDroppingWords) ? .write : .destructive,
            reachesFilesystemOrExecutesCode: reachesFilesystemOrExecutesCode
        )
    }

    // A literal the statement runs is tiered as SQL of its own, and the statement carries the code flag as `DO` does.
    func dynamicSQLClassification(
        _ code: StatementCode,
        grammar: SQLLexicalGrammar,
        depth: Int
    ) -> StatementClassification? {
        guard !Self.definesRoutine(code) else { return nil }
        let body = preparedBody(code, grammar: grammar)
        var prepared: StatementClassification?
        if case .statement(let offset) = body {
            let stored = code.text.substring(from: offset)
            prepared = sqlClassification(stored, grammar: grammar, depth: depth + 1)
        }
        var offsets = Self.executeImmediateLiterals(in: code)
        if case .text(let offset) = body {
            offsets.append(offset)
        }
        offsets += TSQLDynamicSQL.textOffsets(in: code.statement, grammar: grammar)
        return offsets.reduce(prepared) { worst, offset in
            let dynamic = dynamicSQLClassification(at: offset, in: code.text, grammar: grammar)
            return worst?.escalated(with: dynamic) ?? dynamic
        }
    }

    private func dynamicSQLClassification(
        at offset: Int,
        in text: NSString,
        grammar: SQLLexicalGrammar
    ) -> StatementClassification {
        let literalStart = Self.skipNationalPrefix(in: text, from: Self.skipBlanks(in: text, from: offset))
        guard let span = SQLNonCodeSpan.span(at: literalStart, in: text, grammar: grammar), span.kind == .quoted else {
            return StatementClassification(tier: .write, reachesFilesystemOrExecutesCode: true)
        }
        let dynamic = Self.literalBody(of: span, in: text, grammar: grammar)
        let dropsData = StatementCode(dynamic, grammar: grammar).containsAny(Self.dataDroppingWords)
        let inner = classify(dynamic)
        return StatementClassification(
            tier: StatementClassification.worse(inner.tier, dropsData ? .destructive : .write),
            reachesFilesystemOrExecutesCode: true
        )
    }

    /// Where the operand of each `EXECUTE IMMEDIATE` begins. A comment between the words, or before the operand, is
    /// nothing to the engine.
    static func executeImmediateLiterals(in code: StatementCode) -> [Int] {
        code.tokens.indices.compactMap { index in
            guard code.spells(["EXECUTE", "IMMEDIATE"], at: index) else { return nil }
            let operand = code.operand(after: index + 1)
            return code.tokens.indices.contains(operand) ? code.tokens[operand].location : code.text.length
        }
    }

    func preparedBody(_ code: StatementCode, grammar: SQLLexicalGrammar) -> SQLPreparedStatement.Body? {
        guard code.keyword == "PREPARE" else { return nil }
        return SQLPreparedStatement.body(in: code.statement, grammar: grammar)
    }

    static func skipNationalPrefix(in text: NSString, from offset: Int) -> Int {
        guard offset + 1 < text.length, text.character(at: offset + 1) == SqlLexer.singleQuote,
              [SqlLexer.smallN, SqlLexer.capitalN].contains(text.character(at: offset))
        else { return offset }
        return offset + 1
    }

    static func skipBlanks(in text: NSString, from offset: Int) -> Int {
        var cursor = offset
        while cursor < text.length, StatementBlank.blankLength(in: text, at: cursor) > 0 {
            cursor += StatementBlank.blankLength(in: text, at: cursor)
        }
        return cursor
    }

    /// The text between a literal's delimiters: the body of `'...'`, `E'...'`, `b'...'`, `$tag$...$tag$` or `q'[...]'`,
    /// with a doubled quote folded back to one.
    static func literalBody(of span: SQLNonCodeSpan.Span, in text: NSString, grammar: SQLLexicalGrammar) -> String {
        let opener = text.character(at: span.start)
        let bodyStart = min(literalBodyStart(of: span, opener: opener, in: text, grammar: grammar), span.contentEnd)
        let body = text.substring(with: NSRange(location: bodyStart, length: span.contentEnd - bodyStart))
        guard opener == SqlLexer.singleQuote || opener == SqlLexer.doubleQuote else { return body }
        let quote = opener == SqlLexer.singleQuote ? "'" : "\""
        return body.replacingOccurrences(of: quote + quote, with: quote, options: .literal)
    }

    static func literalBodyStart(
        of span: SQLNonCodeSpan.Span,
        opener: UInt16,
        in text: NSString,
        grammar: SQLLexicalGrammar
    ) -> Int {
        switch opener {
        case SqlDollarQuote.dollar:
            var cursor = span.start + 1
            while cursor < span.contentEnd, text.character(at: cursor) != SqlDollarQuote.dollar {
                cursor += 1
            }
            return cursor + 1
        case SqlLexer.singleQuote, SqlLexer.doubleQuote:
            let isTriple = grammar.contains(.tripleQuotedStrings)
                && SqlLexer.startsTripleQuote(text, at: span.start, length: text.length)
            return span.start + (isTriple ? 3 : 1)
        case SqlLexer.smallN, SqlLexer.capitalN, SqlLexer.smallQ, SqlLexer.capitalQ:
            let literal = SqlLexer.skipAlternativeQuotedString(text, at: span.start, length: text.length)
            return literal?.bodyStart ?? span.start + 1
        case escapeStringPrefixes.lower, escapeStringPrefixes.upper, escapeBytesPrefix:
            return span.start + 2
        default:
            return span.start + 1
        }
    }

    static let escapeStringPrefixes = (lower: UInt16(UnicodeScalar("e").value), upper: UInt16(UnicodeScalar("E").value))
    static let escapeBytesPrefix = UInt16(UnicodeScalar("b").value)
}
