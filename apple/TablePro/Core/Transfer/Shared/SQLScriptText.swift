import Foundation
import TableProPluginKit
import TableProSQLGrammar

// The one owner of how SQL text meets an engine: each statement as a driver takes it in one call, and a list of them as
// a script the engine's own client runs. One string serving as both made a saved sync script run only its first DROP.
// Only Oracle, MySQL, PostgreSQL and SQLite text is cut into statements: the generic grammar cuts a T-SQL body with no
// BEGIN, a Dameng declaration section and a Snowflake `$$` body into pieces the server rejects.
nonisolated struct SQLScriptText {
    private static let mysqlScriptDelimiterUnit = "/"

    // MySQL connects without CLIENT_MULTI_STATEMENTS, DuckDB prepares every text and SQLite refuses a tail.
    private static let enginesRefusingASecondStatement: Set<String> = ["SQLite", "DuckDB"]

    private static let oracleGrammar = SQLLexicalReadings.resolve(
        databaseTypeId: "Oracle", declared: nil, session: nil
    ).execution

    let databaseTypeId: String
    private let dialect: SqlDialect
    private let grammar: SQLLexicalGrammar
    private let readings: SQLLexicalReadings

    // `readings` is every way the engine could lex a text; its execution grammar splits the statements.
    init(databaseTypeId: String, readings: SQLLexicalReadings) {
        self.init(databaseTypeId: databaseTypeId, grammar: readings.execution, readings: readings)
    }

    // `grammar` is the session's execution grammar, which a server setting such as KingbaseES Oracle mode changes.
    init(databaseTypeId: String, grammar: SQLLexicalGrammar, readings: SQLLexicalReadings) {
        self.databaseTypeId = databaseTypeId
        self.dialect = SqlDialect.from(databaseTypeId: databaseTypeId)
        self.grammar = grammar
        self.readings = SQLLexicalReadings(execution: grammar, all: readings.all)
    }

    // The statements `text` holds, each exactly as the driver receives it in one call, in order.
    func sendableStatements(_ text: String) -> [String] {
        guard tracksGrammar else {
            let whole = StatementBlank.trimming(text)
            return whole.isEmpty ? [] : [whole]
        }
        return SQLStatementScanner.executableStatements(in: text, grammar: grammar).map(\.sql)
    }

    // Nil when text the app did not write reads as several statements where the driver may run a second one.
    func sendableStatements(ofForeignText text: String) -> [String]? {
        switch foreignTextSending {
        case .split:
            return sendableStatements(text)
        case .whole:
            let whole = Self.withoutOneSeparator(text)
            return whole.isEmpty ? [] : [whole]
        case .oneStatement:
            let statements = sendableStatements(text)
            return statements.count > 1 ? nil : statements
        }
    }

    nonisolated private enum ForeignTextSending {
        case split
        // The driver refuses a second statement in one call, so the server decides where the text ends.
        case whole
        case oneStatement
    }

    private var foreignTextSending: ForeignTextSending {
        switch dialect {
        case .mysql:
            return .whole
        case .sqlite:
            return Self.enginesRefusingASecondStatement.contains(databaseTypeId) ? .whole : .oneStatement
        default:
            return .split
        }
    }

    private static func withoutOneSeparator(_ text: String) -> String {
        let trimmed = StatementBlank.trimming(text)
        guard trimmed.unicodeScalars.last == ";" else { return trimmed }
        return StatementBlank.trimming(String(trimmed.unicodeScalars.dropLast()))
    }

    // The text that decides whether two definitions create the same object. A tracked grammar keeps a unit's own `;`,
    // since Oracle stores a procedure sent without it INVALID; any other engine takes a definition with or without one.
    func comparableText(_ definition: String) -> String {
        guard tracksGrammar else {
            var text = StatementBlank.trimming(definition)
            while text.hasSuffix(";") {
                text = StatementBlank.trimming(String(text.dropLast()))
            }
            return text
        }
        return sendableStatements(definition).joined(separator: ";\n")
    }

    func leadingKeyword(of statement: String) -> String? {
        let text = statement as NSString
        let length = text.length
        var index = 0
        while index < length {
            let blank = StatementBlank.blankLength(in: text, at: index)
            guard blank == 0 else {
                index += blank
                continue
            }
            guard let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar), span.kind.isComment else {
                let head = text.substring(with: NSRange(location: index, length: min(length - index, 64)))
                return String(head.prefix { $0.isLetter }).uppercased()
            }
            index = max(span.end, index + 1)
        }
        return nil
    }

    // Every statement in `statements`, which are sendable texts, written as one script for this engine's client.
    func script(_ statements: [String]) -> String {
        let ended = statements
            .map { StatementBlank.trimming($0) }
            .filter { !$0.isEmpty }
            .map(terminated)
        guard grammar.contains(.batchSeparatorLines) else {
            return ended.joined(separator: "\n")
        }
        return ended.map { "\($0)\nGO" }.joined(separator: "\n")
    }

    // `ddl`, text a driver produced that may hold several statements, as script text for this engine's client.
    func scriptText(forDriverText ddl: String) -> String {
        // A MySQL definition was recorded under its own sql_mode, so the export never cuts it with the session's.
        let statements = dialect == .mysql ? (sendableStatements(ofForeignText: ddl) ?? []) : sendableStatements(ddl)
        return statements.map(terminated).joined(separator: "\n")
    }

    // MARK: - Terminators

    private var tracksGrammar: Bool {
        switch dialect {
        case .oracle, .mysql, .postgres, .sqlite:
            return true
        default:
            return false
        }
    }

    // SQL*Plus reads a unit until a line holding only `/`, and so does Dameng's DISQL: on DM8 a script ending a
    // procedure with `END;` ran the statement before it, then reported "The script file is not complete".
    private var endsUnitsWithSlashLines: Bool {
        dialect == .oracle || Self.slashLineClientEngines.contains(databaseTypeId)
    }

    private static let slashLineClientEngines: Set<String> = ["Dameng"]

    // One sendable statement, ended the way this engine's client ends it.
    private func terminated(_ statement: String) -> String {
        if endsUnitsWithSlashLines {
            return runsAsPLSQLUnit(statement) ? "\(statement)\n/" : endedBySemicolon(statement)
        }
        if dialect == .mysql, holdsInnerSemicolon(statement) {
            return delimiterBlock(statement)
        }
        return endedBySemicolon(statement)
    }

    // Whether the client reads `statement` in PL/SQL mode, where only a `/` line runs it: a definition, which takes no
    // bind parameters, or a block, which keeps its `;`. A CALL trigger is the case a `;` cannot end: Oracle stores it
    // INVALID. Dameng spells the first words the way Oracle does.
    private func runsAsPLSQLUnit(_ statement: String) -> Bool {
        guard let located = SQLStatementScanner.executableStatements(in: statement, grammar: Self.oracleGrammar).first else {
            return false
        }
        return !located.acceptsBindParameters || located.sql.hasSuffix(";")
    }

    // The mysql client reads the body under whatever sql_mode the script set before it, so every reading counts.
    private func holdsInnerSemicolon(_ statement: String) -> Bool {
        var body = statement
        while body.unicodeScalars.last == ";" {
            body = StatementBlank.trimming(String(body.unicodeScalars.dropLast()))
        }
        return readings.distinct(for: body).contains { codeShape(of: body, grammar: $0).holdsSemicolon }
    }

    // Slashes rather than mysqldump's `;;`, which the import reads as a statement ended by its first `;`; never text the body holds.
    private func delimiterBlock(_ statement: String) -> String {
        let text = statement as NSString
        var delimiter = Self.mysqlScriptDelimiterUnit + Self.mysqlScriptDelimiterUnit
        while text.range(of: delimiter, options: .literal).location != NSNotFound {
            delimiter += Self.mysqlScriptDelimiterUnit
        }
        let body = endsInLineComment(statement)
            ? "\(statement)\n\(delimiter)"
            : "\(statement) \(delimiter)"
        return "DELIMITER \(delimiter)\n\(body)\nDELIMITER ;"
    }

    // A comment the text leaves open would run over the terminator, even one the text already ends with: SQLite stores
    // `STRICT /* open` and `-- note` after a definition as written.
    func endedBySemicolon(_ statement: String) -> String {
        let shapes = readings.distinct(for: statement).map { codeShape(of: statement, grammar: $0) }
        if shapes.contains(where: \.endsInOpenBlockComment) {
            return "\(statement) */;"
        }
        if shapes.contains(where: \.endsInLineComment) {
            return "\(statement)\n;"
        }
        return statement.unicodeScalars.last == ";" ? statement : "\(statement);"
    }

    private func endsInLineComment(_ statement: String) -> Bool {
        readings.distinct(for: statement).contains { codeShape(of: statement, grammar: $0).endsInLineComment }
    }

    nonisolated private struct CodeShape {
        var holdsSemicolon = false
        var endsInLineComment = false
        var endsInOpenBlockComment = false
    }

    private func codeShape(of statement: String, grammar: SQLLexicalGrammar) -> CodeShape {
        let text = statement as NSString
        let length = text.length
        var shape = CodeShape()
        var index = 0
        while index < length {
            if let end = SQLNonCodeSpan.end(at: index, in: text, grammar: grammar) {
                if end >= length, startsLineComment(text, at: index, length: length, grammar: grammar) {
                    shape.endsInLineComment = true
                }
                if end >= length, let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar),
                   span.kind == .blockComment, !span.isTerminated {
                    shape.endsInOpenBlockComment = true
                }
                index = max(end, index + 1)
                continue
            }
            if text.character(at: index) == SqlLexer.semicolon {
                shape.holdsSemicolon = true
            }
            index += 1
        }
        return shape
    }

    private func startsLineComment(_ text: NSString, at index: Int, length: Int, grammar: SQLLexicalGrammar) -> Bool {
        SqlLexer.startsLineComment(text, at: index, length: length)
            || (grammar.contains(.hashLineComments) && text.character(at: index) == SqlLexer.hash)
    }
}
