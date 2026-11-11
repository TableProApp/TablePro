import Foundation

public struct SQLSessionStateKinds: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let temporaryObjects = SQLSessionStateKinds(rawValue: 1 << 0)
    public static let sessionSettings = SQLSessionStateKinds(rawValue: 1 << 1)
    public static let userVariables = SQLSessionStateKinds(rawValue: 1 << 2)
    public static let preparedStatements = SQLSessionStateKinds(rawValue: 1 << 3)
    public static let heldCursors = SQLSessionStateKinds(rawValue: 1 << 4)
    public static let sessionLocks = SQLSessionStateKinds(rawValue: 1 << 5)
    public static let listeners = SQLSessionStateKinds(rawValue: 1 << 6)

    public static let all: SQLSessionStateKinds = [
        .temporaryObjects, .sessionSettings, .userVariables, .preparedStatements, .heldCursors, .sessionLocks,
        .listeners,
    ]
}

public struct SQLSessionStateEffect: Sendable, Equatable {
    public let creates: SQLSessionStateKinds
    public let clears: SQLSessionStateKinds

    public init(creates: SQLSessionStateKinds = [], clears: SQLSessionStateKinds = []) {
        self.creates = creates
        self.clears = clears
    }

    public static let none = SQLSessionStateEffect()

    public var isEmpty: Bool {
        creates.isEmpty && clears.isEmpty
    }

    public func followed(by next: SQLSessionStateEffect) -> SQLSessionStateEffect {
        SQLSessionStateEffect(
            creates: creates.subtracting(next.clears).union(next.creates),
            clears: clears.union(next.clears)
        )
    }

    public func applied(to kinds: SQLSessionStateKinds) -> SQLSessionStateKinds {
        kinds.subtracting(clears).union(creates)
    }
}

public enum SQLSessionDialect: Sendable, Hashable {
    case postgres
    case mySQL
    case sqlServer
    case oracle
    case sqlite
    case duckDB
}

// No engine reports a session's temporary tables, settings or variables, and a dead connection answers nothing, so
// the text decides. A `CALL`, `DO`, `EXEC proc` or PL/SQL block is not read: what it sets up is out of sight.
public enum SQLSessionStateClassifier: Sendable {
    // Past this a text is data, an INSERT's VALUES, and reading it all would cost a pass per run. Each text is cut before
    // it is split, so a setup past this point in one long text, such as a T-SQL batch with no `;`, is not seen.
    private static let classifiedPrefixLength = 65_536
    private static let modifierLookahead = 5

    private static let period = UInt16(UnicodeScalar(".").value)
    private static let atSign = UInt16(UnicodeScalar("@").value)
    private static let colon = UInt16(UnicodeScalar(":").value)
    private static let equals = UInt16(UnicodeScalar("=").value)

    // What `skipping` names runs again on every new connection, such as a startup command, so it is never lost.
    public static func effect(
        ofStatements statements: [String],
        dialect: SQLSessionDialect,
        grammar: SQLLexicalGrammar,
        skipping skipped: [String] = []
    ) -> SQLSessionStateEffect {
        let skippedTexts = Set(skipped.map(comparableText))
        var effect = SQLSessionStateEffect.none
        for text in statements {
            let head = classifiedHead(of: text)
            guard SQLSessionStateQuickCheck.mayChangeSession(head, dialect: dialect) else { continue }
            for statement in SQLStatementClassifier.statements(of: head, grammar: grammar)
            where SQLSessionStateQuickCheck.mayChangeSession(statement, dialect: dialect)
                && !skippedTexts.contains(comparableText(statement)) {
                effect = effect.followed(by: statementEffect(of: statement, dialect: dialect, grammar: grammar))
            }
        }
        return effect
    }

    public static func effect(of sql: String, dialect: SQLSessionDialect, grammar: SQLLexicalGrammar) -> SQLSessionStateEffect {
        effect(ofStatements: [sql], dialect: dialect, grammar: grammar)
    }

    static func comparableText(_ statement: String) -> String {
        var text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // Every server reading of a `/*!` comment counts what it sets up, and only what all of them clear is cleared.
    private static func statementEffect(
        of statement: String,
        dialect: SQLSessionDialect,
        grammar: SQLLexicalGrammar
    ) -> SQLSessionStateEffect {
        // More versions than a reader takes one by one leaves the text as written, its executable comments unread.
        let texts = SQLExecutableCommentReadings.texts(of: statement, grammar: grammar).map { Array($0) } ?? [statement]
        var creates: SQLSessionStateKinds = []
        var clears: SQLSessionStateKinds?
        for text in texts {
            let reading = SQLStatementClassifier.runnableStatements(of: text, grammar: grammar)
                .reduce(SQLSessionStateEffect.none) { partial, piece in
                    partial.followed(by: pieceEffect(of: piece, dialect: dialect, grammar: grammar))
                }
            creates.formUnion(reading.creates)
            clears = clears.map { $0.intersection(reading.clears) } ?? reading.clears
        }
        return SQLSessionStateEffect(creates: creates, clears: clears ?? [])
    }

    private static func classifiedHead(of statement: String) -> String {
        let text = statement as NSString
        guard text.length > classifiedPrefixLength else { return statement }
        let cut = text.rangeOfComposedCharacterSequence(at: classifiedPrefixLength).location
        return text.substring(to: cut)
    }

    private static func pieceEffect(
        of piece: String,
        dialect: SQLSessionDialect,
        grammar: SQLLexicalGrammar
    ) -> SQLSessionStateEffect {
        guard !SQLProceduralBlock.runs(piece, grammar: grammar) else { return .none }
        let code = StatementCode(piece, grammar: grammar)
        guard let start = code.tokens.firstIndex(where: { $0.kind != .open }), code.tokens[start].word != nil else {
            return .none
        }
        switch dialect {
        case .postgres:
            return postgresEffect(code, start: start)
        case .mySQL:
            return SQLSessionStateEffect(creates: mySQLKinds(code, start: start))
        case .sqlServer:
            return SQLSessionStateEffect(creates: sqlServerKinds(code, start: start))
        case .oracle:
            return SQLSessionStateEffect(creates: oracleKinds(code, start: start))
        case .sqlite:
            return SQLSessionStateEffect(creates: sqliteKinds(code, start: start))
        case .duckDB:
            return SQLSessionStateEffect(creates: duckDBKinds(code, start: start))
        }
    }
}

// MARK: - PostgreSQL

extension SQLSessionStateClassifier {
    private static let postgresObjectKinds: Set<String> = ["TABLE", "VIEW", "SEQUENCE", "FUNCTION", "PROCEDURE", "TYPE"]

    // `SET LOCAL` lasts until the transaction ends, `SET TRANSACTION` covers one, and `SET CONSTRAINTS` the current one.
    private static let postgresTransactionScopedSets: Set<String> = ["LOCAL", "TRANSACTION", "CONSTRAINTS"]

    // KingbaseES ships each `pg_` function under a `sys_` name too. The `_xact_` forms end with the transaction.
    private static let postgresSessionLockFunctions: Set<String> = [
        "PG_ADVISORY_LOCK", "PG_ADVISORY_LOCK_SHARED", "PG_TRY_ADVISORY_LOCK", "PG_TRY_ADVISORY_LOCK_SHARED",
        "SYS_ADVISORY_LOCK", "SYS_ADVISORY_LOCK_SHARED", "SYS_TRY_ADVISORY_LOCK", "SYS_TRY_ADVISORY_LOCK_SHARED",
    ]

    private static func postgresEffect(_ code: StatementCode, start: Int) -> SQLSessionStateEffect {
        let keyword = code.word(at: start) ?? ""
        let next = code.word(at: start + 1)
        // A prepared statement runs what it holds only when executed.
        var kinds: SQLSessionStateKinds = keyword == "PREPARE" ? [] : postgresCallKinds(code)
        switch keyword {
        case "CREATE":
            let temporary = createsTemporary(code, after: start, kinds: postgresObjectKinds)
                || createsInSchema(code, after: start, kinds: postgresObjectKinds) { $0.hasPrefix("PG_TEMP") }
            // `ON COMMIT DROP` ends the table with the transaction.
            if temporary, !code.tokens.indices.contains(where: { code.spells(["ON", "COMMIT", "DROP"], at: $0) }) {
                kinds.insert(.temporaryObjects)
            }
        case "SELECT", "WITH":
            if selectsIntoPostgresTemporary(code) {
                kinds.insert(.temporaryObjects)
            }
        case "SET":
            if let next, !postgresTransactionScopedSets.contains(next) {
                kinds.insert(.sessionSettings)
            }
        case "PREPARE":
            if next != nil, next != "TRANSACTION" {
                kinds.insert(.preparedStatements)
            }
        case "DECLARE":
            if declaresHeldCursor(code, after: start) {
                kinds.insert(.heldCursors)
            }
        case "LISTEN":
            kinds.insert(.listeners)
        case "DISCARD":
            switch next {
            case "ALL":
                // `RESET ALL` is no clear: `role` and `session_authorization` are `GUC_NO_RESET_ALL`, and only this
                // resets them too.
                return SQLSessionStateEffect(creates: kinds, clears: .all)
            case "TEMP", "TEMPORARY":
                return SQLSessionStateEffect(creates: kinds, clears: .temporaryObjects)
            default:
                break
            }
        case "DEALLOCATE":
            let target = next == "PREPARE" ? code.word(at: start + 2) : next
            if target == "ALL" {
                return SQLSessionStateEffect(creates: kinds, clears: .preparedStatements)
            }
        case "UNLISTEN":
            if code.isSymbol(SqlLexer.star, at: start + 1) {
                return SQLSessionStateEffect(creates: kinds, clears: .listeners)
            }
        default:
            break
        }
        return SQLSessionStateEffect(creates: kinds)
    }

    private static func postgresCallKinds(_ code: StatementCode) -> SQLSessionStateKinds {
        var kinds: SQLSessionStateKinds = []
        for index in code.tokens.indices where code.opensCall(at: index) {
            guard let name = code.word(at: index) else { continue }
            if postgresSessionLockFunctions.contains(name) {
                kinds.insert(.sessionLocks)
            } else if name == "SET_CONFIG", !isTransactionLocalSetConfig(code, opening: index + 1) {
                kinds.insert(.sessionSettings)
            }
        }
        return kinds
    }

    // `set_config(name, value, true)` lasts until the transaction ends.
    private static func isTransactionLocalSetConfig(_ code: StatementCode, opening open: Int) -> Bool {
        let outside = code.tokens[open].depth
        var argument = 0
        var third: [TSQLTokens.Token] = []
        var index = open + 1
        while index < code.tokens.count {
            let token = code.tokens[index]
            if token.kind == .close, token.depth == outside { break }
            if token.kind == .comma, token.depth == outside + 1 {
                argument += 1
            } else if argument == 2 {
                third.append(token)
            }
            index += 1
        }
        return third.count == 1 && third[0].word == "TRUE"
    }

    private static func selectsIntoPostgresTemporary(_ code: StatementCode) -> Bool {
        code.tokens.indices.contains { index in
            guard code.word(at: index) == "INTO", let target = code.word(at: index + 1) else { return false }
            return target == "TEMP" || target == "TEMPORARY"
                || (target.hasPrefix("PG_TEMP") && code.isSymbol(period, at: index + 2))
        }
    }

    // A cursor outlives its transaction only `WITH HOLD`.
    private static func declaresHeldCursor(_ code: StatementCode, after start: Int) -> Bool {
        let end = code.tokens[(start + 1)...].firstIndex { $0.word == "FOR" } ?? code.tokens.count
        return ((start + 1)..<end).contains { code.spells(["WITH", "HOLD"], at: $0) }
    }
}

// MARK: - MySQL and MariaDB

extension SQLSessionStateClassifier {
    private static let mySQLGlobalScopes: Set<String> = ["GLOBAL", "PERSIST", "PERSIST_ONLY"]
    private static let mySQLSessionScopes: Set<String> = ["SESSION", "LOCAL"]

    private static func mySQLKinds(_ code: StatementCode, start: Int) -> SQLSessionStateKinds {
        let keyword = code.word(at: start) ?? ""
        let next = code.word(at: start + 1)
        var kinds: SQLSessionStateKinds = []
        switch keyword {
        case "CREATE":
            if createsTemporary(code, after: start, kinds: ["TABLE"]) {
                kinds.insert(.temporaryObjects)
            }
        case "SET":
            kinds.formUnion(mySQLSetKinds(code, from: start + 1))
        case "PREPARE":
            return next == nil ? [] : [.preparedStatements]
        case "LOCK":
            if next == "TABLE" || next == "TABLES" {
                kinds.insert(.sessionLocks)
            }
        default:
            break
        }
        if code.tokens.indices.contains(where: { code.opensCall(at: $0) && code.word(at: $0) == "GET_LOCK" }) {
            kinds.insert(.sessionLocks)
        }
        if assignsMySQLUserVariable(code) {
            kinds.insert(.userVariables)
        }
        return kinds
    }

    // Plain `SET TRANSACTION` covers the next transaction only, `SET PASSWORD` and `SET DEFAULT ROLE` change the
    // account, and MariaDB's `SET STATEMENT ... FOR` one statement.
    private static func mySQLSetKinds(_ code: StatementCode, from first: Int) -> SQLSessionStateKinds {
        guard code.tokens.indices.contains(first) else { return [] }
        let next = code.word(at: first)
        let after = code.word(at: first + 1)
        if after == "TRANSACTION", let next {
            return mySQLSessionScopes.contains(next) ? [.sessionSettings] : []
        }
        switch next {
        case "PASSWORD", "STATEMENT", "TRANSACTION", "RESOURCE":
            return []
        case "DEFAULT" where after == "ROLE":
            return []
        case "NAMES", "CHARACTER", "CHARSET", "ROLE":
            return [.sessionSettings]
        default:
            break
        }
        return mySQLAssignmentKinds(code, from: first)
    }

    // A scope word sets the scope of the assignments after it that name none, as the manual says.
    private static func mySQLAssignmentKinds(_ code: StatementCode, from first: Int) -> SQLSessionStateKinds {
        let depth = code.tokens[first].depth
        var kinds: SQLSessionStateKinds = []
        var sessionScope = true
        var startsAssignment = true
        for index in first..<code.tokens.count {
            let token = code.tokens[index]
            if token.kind == .comma, token.depth == depth {
                startsAssignment = true
                continue
            }
            guard startsAssignment else { continue }
            startsAssignment = false
            if code.isSymbol(atSign, at: index) {
                guard code.isSymbol(atSign, at: index + 1) else {
                    kinds.insert(.userVariables)
                    continue
                }
                let scope = code.word(at: index + 2)
                let isGlobal = scope.map(mySQLGlobalScopes.contains) == true && code.isSymbol(period, at: index + 3)
                if !isGlobal {
                    kinds.insert(.sessionSettings)
                }
            } else if let word = token.word {
                if mySQLGlobalScopes.contains(word) {
                    sessionScope = false
                } else if mySQLSessionScopes.contains(word) {
                    sessionScope = true
                    kinds.insert(.sessionSettings)
                } else if sessionScope {
                    kinds.insert(.sessionSettings)
                }
            }
        }
        return kinds
    }

    // `@v := expr` anywhere, or `INTO @v` after a query. A `@@` is a system variable, which a statement only reads.
    private static func assignsMySQLUserVariable(_ code: StatementCode) -> Bool {
        code.tokens.indices.contains { index in
            guard code.isSymbol(atSign, at: index), !code.isSymbol(atSign, at: index - 1),
                  !code.isSymbol(atSign, at: index + 1)
            else { return false }
            if code.word(at: index - 1) == "INTO" { return true }
            return code.isSymbol(colon, at: index + 2) && code.isSymbol(equals, at: index + 3)
        }
    }
}

// MARK: - SQL Server

extension SQLSessionStateClassifier {
    private static let sqlServerTemporaryKinds: Set<String> = ["TABLE", "PROC", "PROCEDURE"]

    private static func sqlServerKinds(_ code: StatementCode, start: Int) -> SQLSessionStateKinds {
        let keyword = code.word(at: start) ?? ""
        let next = code.word(at: start + 1)
        switch keyword {
        case "CREATE":
            return createsSQLServerTemporary(code, after: start) ? [.temporaryObjects] : []
        case "SELECT", "WITH":
            let intoTemporary = code.tokens.indices.contains { index in
                code.word(at: index) == "INTO" && namesSQLServerTemporary(code, at: index + 1)
            }
            return intoTemporary ? [.temporaryObjects] : []
        case "SET":
            // A `@variable` dies with its batch.
            guard let next, !next.hasPrefix("@") else { return [] }
            return [.sessionSettings]
        case "EXEC", "EXECUTE":
            // `EXECUTE AS` impersonates until a `REVERT`.
            return next == "AS" ? [.sessionSettings] : sqlServerProcedureKinds(code, nameAt: start + 1)
        case "DECLARE":
            return declaresGlobalCursor(code, after: start) ? [.heldCursors] : []
        default:
            // A batch that opens with a procedure's name runs it.
            return sqlServerProcedureKinds(code, nameAt: start)
        }
    }

    private static func createsSQLServerTemporary(_ code: StatementCode, after start: Int) -> Bool {
        let window = (start + 1)..<min(start + 1 + modifierLookahead, code.tokens.count)
        guard let kind = window.first(where: { code.word(at: $0).map(sqlServerTemporaryKinds.contains) == true }) else {
            return false
        }
        return namesSQLServerTemporary(code, at: kind + 1)
    }

    // `#t`, `[#t]` and `"#t"` all name a temporary table, and so does `#tëmp`, which reads as a name, not a word.
    private static func namesSQLServerTemporary(_ code: StatementCode, at index: Int) -> Bool {
        guard code.tokens.indices.contains(index) else { return false }
        let token = code.tokens[index]
        let first: Int
        switch token.kind {
        case .word, .name:
            first = token.location
        case .quoted:
            first = token.location + 1
        default:
            return false
        }
        return first < code.text.length && code.text.character(at: first) == SqlLexer.hash
    }

    private static func sqlServerProcedureKinds(_ code: StatementCode, nameAt start: Int) -> SQLSessionStateKinds {
        var index = start
        if code.word(at: index)?.hasPrefix("@") == true, code.isSymbol(equals, at: index + 1) {
            index += 2
        }
        while code.isSymbol(period, at: index + 1), code.word(at: index + 2) != nil {
            index += 2
        }
        switch code.word(at: index) {
        // An application role holds the session's security context until `sp_unsetapprole` or the end of the session.
        case "SP_SET_SESSION_CONTEXT", "SP_SETAPPROLE":
            return [.sessionSettings]
        case "SP_GETAPPLOCK":
            return [.sessionLocks]
        default:
            return []
        }
    }

    // A cursor is global unless declared `LOCAL`; a cursor variable `DECLARE @c CURSOR` dies with its batch.
    private static func declaresGlobalCursor(_ code: StatementCode, after start: Int) -> Bool {
        guard let name = code.word(at: start + 1), !name.hasPrefix("@") else { return false }
        let end = code.tokens[(start + 1)...].firstIndex { $0.word == "FOR" } ?? code.tokens.count
        let words = code.tokens[(start + 1)..<end].compactMap { $0.word }
        return words.contains("CURSOR") && !words.contains("LOCAL")
    }
}

// MARK: - Oracle, SQLite and DuckDB

extension SQLSessionStateClassifier {
    private static let oracleSessionVerbs: Set<String> = ["SET", "ENABLE", "DISABLE", "FORCE"]
    private static let sqliteObjectKinds: Set<String> = ["TABLE", "VIEW", "TRIGGER", "INDEX"]
    private static let duckDBObjectKinds: Set<String> = ["TABLE", "VIEW", "SEQUENCE", "MACRO", "FUNCTION", "TYPE"]

    // Rows in a global temporary table are not counted: the table itself is permanent.
    private static func oracleKinds(_ code: StatementCode, start: Int) -> SQLSessionStateKinds {
        let next = code.word(at: start + 1)
        switch code.word(at: start) {
        case "ALTER":
            let verb = code.word(at: start + 2)
            return next == "SESSION" && verb.map(oracleSessionVerbs.contains) == true ? [.sessionSettings] : []
        case "SET":
            return next == "ROLE" ? [.sessionSettings] : []
        case "CREATE":
            // A private temporary table goes at commit unless it keeps its definition.
            let isPrivate = code.spells(["PRIVATE", "TEMPORARY", "TABLE"], at: start + 1)
            let preserved = code.tokens.indices.contains { code.spells(["PRESERVE", "DEFINITION"], at: $0) }
            return isPrivate && preserved ? [.temporaryObjects] : []
        default:
            return []
        }
    }

    private static func sqliteKinds(_ code: StatementCode, start: Int) -> SQLSessionStateKinds {
        guard code.word(at: start) == "CREATE" else { return [] }
        let temporary = createsTemporary(code, after: start, kinds: sqliteObjectKinds)
            || createsInSchema(code, after: start, kinds: sqliteObjectKinds) { $0 == "TEMP" }
        return temporary ? [.temporaryObjects] : []
    }

    private static func duckDBKinds(_ code: StatementCode, start: Int) -> SQLSessionStateKinds {
        let next = code.word(at: start + 1)
        switch code.word(at: start) {
        case "CREATE":
            let temporary = createsTemporary(code, after: start, kinds: duckDBObjectKinds)
                || createsInSchema(code, after: start, kinds: duckDBObjectKinds) { $0 == "TEMP" }
            return temporary ? [.temporaryObjects] : []
        case "SET":
            switch next {
            case nil, "GLOBAL", "LOCAL":
                return []
            case "VARIABLE":
                return [.userVariables]
            default:
                return [.sessionSettings]
            }
        default:
            return []
        }
    }
}

// MARK: - Shared readings

extension SQLSessionStateClassifier {
    private static let temporaryMarkers: Set<String> = ["TEMP", "TEMPORARY"]

    // `CREATE [OR REPLACE] [GLOBAL | LOCAL] TEMP TABLE`: the marker stands before the kind, a few words in.
    private static func createsTemporary(_ code: StatementCode, after start: Int, kinds: Set<String>) -> Bool {
        for index in (start + 1)..<min(start + 1 + modifierLookahead, code.tokens.count) {
            guard let word = code.word(at: index) else { return false }
            if temporaryMarkers.contains(word) { return true }
            if kinds.contains(word) { return false }
        }
        return false
    }

    // `CREATE TABLE pg_temp.t`: a name in the session's own schema is temporary without the marker.
    private static func createsInSchema(
        _ code: StatementCode,
        after start: Int,
        kinds: Set<String>,
        schema isTemporarySchema: (String) -> Bool
    ) -> Bool {
        let window = (start + 1)..<min(start + 1 + modifierLookahead, code.tokens.count)
        guard let kind = window.first(where: { code.word(at: $0).map(kinds.contains) == true }) else { return false }
        var name = kind + 1
        if code.spells(["IF", "NOT", "EXISTS"], at: name) {
            name += 3
        }
        guard let word = code.word(at: name), isTemporarySchema(word) else { return false }
        return code.isSymbol(period, at: name + 1)
    }
}

fileprivate extension StatementCode {
    func word(at index: Int) -> String? {
        tokens.indices.contains(index) ? tokens[index].word : nil
    }

    func opensCall(at index: Int) -> Bool {
        tokens.indices.contains(index + 1) && tokens[index].word != nil && tokens[index + 1].kind == .open
    }
}

// Whole words, read without the grammar: a hit inside a comment or a literal only costs the full read, and a data word
// such as `offset`, `block` or `template`, or an email address, is no hit. Every rule above needs one of these.
enum SQLSessionStateQuickCheck: Sendable {
    private static let atSign = UInt16(UnicodeScalar("@").value)
    private static let colon = UInt16(UnicodeScalar(":").value)
    private static let equals = UInt16(UnicodeScalar("=").value)
    private static let shortestWord = 3
    private static let longestWord = 32

    private static let postgresWords: Set<String> = [
        "TEMP", "TEMPORARY", "SET", "SET_CONFIG", "PREPARE", "DECLARE", "LISTEN", "UNLISTEN", "DISCARD", "DEALLOCATE",
        "PG_ADVISORY_LOCK", "PG_ADVISORY_LOCK_SHARED", "PG_TRY_ADVISORY_LOCK", "PG_TRY_ADVISORY_LOCK_SHARED",
        "SYS_ADVISORY_LOCK", "SYS_ADVISORY_LOCK_SHARED", "SYS_TRY_ADVISORY_LOCK", "SYS_TRY_ADVISORY_LOCK_SHARED",
    ]
    private static let mySQLWords: Set<String> = ["TEMP", "TEMPORARY", "SET", "PREPARE", "LOCK", "GET_LOCK"]
    private static let sqlServerWords: Set<String> = [
        "SET", "EXEC", "EXECUTE", "DECLARE", "SP_SET_SESSION_CONTEXT", "SP_GETAPPLOCK", "SP_SETAPPROLE",
    ]
    private static let oracleWords: Set<String> = ["SESSION", "ROLE", "PRIVATE"]
    private static let sqliteWords: Set<String> = ["TEMP", "TEMPORARY"]
    private static let duckDBWords: Set<String> = ["TEMP", "TEMPORARY", "SET"]

    static func mayChangeSession(_ text: String, dialect: SQLSessionDialect) -> Bool {
        let units = text as NSString
        let length = units.length
        let triggers = words(for: dialect)
        var lastWord = ""
        var lastWordEnd = -1
        var index = 0
        while index < length {
            let unit = units.character(at: index)
            if isWordUnit(unit) {
                let start = index
                while index < length, isWordUnit(units.character(at: index)) {
                    index += 1
                }
                let count = index - start
                lastWord = count >= shortestWord && count <= longestWord
                    ? units.substring(with: NSRange(location: start, length: count)).uppercased()
                    : ""
                lastWordEnd = index
                if triggers.contains(lastWord) || (dialect == .postgres && lastWord.hasPrefix("PG_TEMP")) {
                    return true
                }
                continue
            }
            if dialect == .mySQL, unit == atSign,
               mayAssignMySQLVariable(units, at: index, gluedToInto: lastWord == "INTO" && lastWordEnd == index) {
                return true
            }
            if dialect == .sqlServer, unit == SqlLexer.hash, startsSQLServerName(units, at: index) {
                return true
            }
            index += 1
        }
        return false
    }

    private static func words(for dialect: SQLSessionDialect) -> Set<String> {
        switch dialect {
        case .postgres: return postgresWords
        case .mySQL: return mySQLWords
        case .sqlServer: return sqlServerWords
        case .oracle: return oracleWords
        case .sqlite: return sqliteWords
        case .duckDB: return duckDBWords
        }
    }

    // ASCII letters and `_`: a digit or `$` ends the run, so `1SET` still holds the `SET` the server reads.
    private static func isWordUnit(_ unit: UInt16) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit == 0x5F
    }

    private static func isNameUnit(_ unit: UInt16) -> Bool {
        isWordUnit(unit) || (0x30...0x39).contains(unit) || unit == 0x24 || unit >= 0x80
    }

    // An address glues its `@` to the name before it, as in `ana@example.com`. A variable stands apart, follows
    // `INTO`, or is assigned with `:=`. A second `@` makes a system variable, which a statement only reads.
    private static func mayAssignMySQLVariable(_ text: NSString, at index: Int, gluedToInto: Bool) -> Bool {
        let length = text.length
        if index > 0, text.character(at: index - 1) == atSign { return false }
        guard index + 1 < length, text.character(at: index + 1) != atSign else { return false }
        if gluedToInto { return true }
        let previous = index > 0 ? text.character(at: index - 1) : SqlLexer.space
        if !isNameUnit(previous), !"._%+-".utf16.contains(previous) { return true }
        return assignedWithColonEquals(text, after: index)
    }

    private static func assignedWithColonEquals(_ text: NSString, after index: Int) -> Bool {
        let length = text.length
        var cursor = index + 1
        let opener = text.character(at: cursor)
        if opener == SqlLexer.singleQuote || opener == SqlLexer.doubleQuote || opener == SqlLexer.backtick {
            cursor += 1
            while cursor < length, text.character(at: cursor) != opener {
                cursor += 1
            }
            cursor += 1
        } else {
            while cursor < length, isNameUnit(text.character(at: cursor)) {
                cursor += 1
            }
        }
        cursor = pastBlanksAndBlockComments(text, from: cursor)
        return cursor + 1 < length && text.character(at: cursor) == colon && text.character(at: cursor + 1) == equals
    }

    private static func pastBlanksAndBlockComments(_ text: NSString, from start: Int) -> Int {
        let length = text.length
        var cursor = start
        while cursor < length {
            let blank = StatementBlank.blankLength(in: text, at: cursor)
            if blank > 0 {
                cursor += blank
                continue
            }
            guard cursor + 1 < length, text.character(at: cursor) == SqlLexer.slash,
                  text.character(at: cursor + 1) == SqlLexer.star
            else { break }
            let close = text.range(
                of: "*/", options: [], range: NSRange(location: cursor + 2, length: length - cursor - 2)
            )
            guard close.location != NSNotFound else { return length }
            cursor = NSMaxRange(close)
        }
        return cursor
    }

    // `#t`, `##t`, `[#t]` and `"#t"`: a `#` that begins a name. One inside a name, `a#b`, is part of it.
    private static func startsSQLServerName(_ text: NSString, at index: Int) -> Bool {
        let length = text.length
        guard index + 1 < length else { return false }
        if index > 0 {
            let previous = text.character(at: index - 1)
            if isNameUnit(previous) || previous == SqlLexer.hash || previous == atSign { return false }
        }
        let next = text.character(at: index + 1)
        return isNameUnit(next) || next == SqlLexer.hash
    }
}
