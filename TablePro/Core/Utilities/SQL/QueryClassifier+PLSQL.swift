//
//  QueryClassifier+PLSQL.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

/// Tiering Oracle statements that run PL/SQL by what they run rather than by their first word.
///
/// Once the editor keeps a unit whole, its leading keyword is all a keyword classifier would see: a `DROP` inside
/// `EXECUTE IMMEDIATE` would pass as a plain write in a block, and as a safe read in a query whose `WITH` clause
/// declares a function. Both run server-side code the moment they are sent, exactly as PostgreSQL's `DO` does, so both
/// carry the same flag that keeps them away from external clients, and their tier is the worst of the statements they
/// spell out and never below a write. Dynamic SQL built from variables cannot be read, which leaves it where a `CALL`
/// of a stored procedure is: a write whose effect the text does not show.
extension QueryClassifier {
    static func runsPLSQL(_ sql: String, databaseType: DatabaseType) -> Bool {
        guard SqlDialect.from(databaseTypeId: databaseType.rawValue) == .oracle else { return false }
        return startsPLSQL(sql)
    }

    /// An anonymous block opens with `DECLARE` or `BEGIN`, after any number of `<<label>>` prefixes and comments. A
    /// query runs PL/SQL when its `WITH` clause opens with a `FUNCTION` or `PROCEDURE` declaration.
    static func startsPLSQL(_ sql: String) -> Bool {
        var head = strippingLeadingComments(sql)
        while head.hasPrefix("<<") {
            guard let close = head.range(of: ">>") else { return false }
            head = strippingLeadingComments(String(head[close.upperBound...]))
        }
        let keyword = leadingWord(of: head)
        if keyword == "DECLARE" || keyword == "BEGIN" { return true }
        guard keyword == "WITH" else { return false }
        let declaration = leadingWord(of: strippingLeadingComments(String(head.dropFirst(keyword.count))))
        return declaration == "FUNCTION" || declaration == "PROCEDURE"
    }

    private static func leadingWord(of text: String) -> String {
        text.prefix { $0.isLetter || $0.isNumber || $0 == "_" }.uppercased()
    }

    static func plsqlBlockClassification(_ trimmed: String, databaseType: DatabaseType) -> QueryClassification {
        let body = oracleCode(of: trimmed)
        var tier: QueryTier = containsKeyword(body, plsqlDestructiveWordRegex) ? .destructive : .write
        for statement in dynamicStatements(in: trimmed) {
            tier = QueryClassification.worse(tier, classifyTier(statement, databaseType: databaseType))
        }
        return QueryClassification(tier: tier, reachesFilesystemOrExecutesCode: true)
    }

    /// Whether the block deletes without a `WHERE`, in its own text or in a statement it builds from a literal.
    static func plsqlBlockDeletesEverything(_ trimmed: String) -> Bool {
        let body = oracleCode(of: trimmed)
        let spelledOut = body.split(separator: ";").contains { segment in
            deletesWithoutWhere(String(segment))
        }
        guard !spelledOut else { return true }
        return dynamicStatements(in: trimmed).contains { statement in
            deletesWithoutWhere(oracleCode(of: statement))
        }
    }

    // MARK: - Private

    private static let plsqlDestructiveWordRegex = try? NSRegularExpression(pattern: #"\b(DROP|TRUNCATE)\b"#)
    private static let whereWordRegex = try? NSRegularExpression(pattern: #"\sWHERE\s"#)
    private static let oracleRules = SQLLexicalRules(dialect: .oracle)

    /// The block's code with every literal and comment blanked, read by Oracle's own rules: a backslash never escapes
    /// a quote, and `q'[...]'` is one literal. The generic stripper would let `'C:\temp\'` run on past its closing
    /// quote and hide whatever statement follows it.
    private static func oracleCode(of sql: String) -> String {
        let text = sql as NSString
        let length = text.length
        var code = ""
        var index = 0
        var runStart = 0
        while index < length {
            guard let end = SQLNonCodeSpan.end(at: index, in: text, rules: oracleRules) else {
                index += 1
                continue
            }
            code += text.substring(with: NSRange(location: runStart, length: index - runStart)) + " "
            index = max(end, index + 1)
            runStart = index
        }
        code += text.substring(from: min(runStart, length))
        return code.uppercased()
    }

    /// Whether `regex` matches a keyword rather than a member name: `v_list.DELETE` is a collection method, not a
    /// statement.
    private static func containsKeyword(_ code: String, _ regex: NSRegularExpression?) -> Bool {
        firstKeyword(in: code, regex) != nil
    }

    private static func firstKeyword(in code: String, _ regex: NSRegularExpression?) -> NSRange? {
        guard let regex else { return nil }
        let text = code as NSString
        return regex.matches(in: code, range: NSRange(location: 0, length: text.length)).first { match in
            var before = match.range.location - 1
            while before >= 0, StatementBlank.blankLength(in: text, at: before) > 0 {
                before -= 1
            }
            return before < 0 || text.character(at: before) != UInt16(UnicodeScalar(".").value)
        }?.range
    }

    /// The documented entry points that run a statement built at run time. The statement is read only when it is
    /// written out as a literal, which is the only form the text can show.
    private static let dynamicStatementOpeners: [NSRegularExpression] = [
        #"\bEXECUTE\s+IMMEDIATE\s+"#,
        #"\bEXEC_DDL_STATEMENT\s*\(\s*"#,
        #"\bDBMS_SQL\s*\.\s*PARSE\s*\([^,;]*,\s*"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let deleteWordRegex = try? NSRegularExpression(pattern: #"\bDELETE\b"#, options: [])

    private static func dynamicStatements(in sql: String) -> [String] {
        let text = sql as NSString
        let whole = NSRange(location: 0, length: text.length)
        return dynamicStatementOpeners.flatMap { opener in
            opener.matches(in: sql, range: whole).compactMap { match in
                literal(in: text, at: match.range.location + match.range.length)
            }
        }
    }

    /// The body of the string literal starting at `offset`, either `'...'` with doubled quotes folded or Oracle's
    /// `q'[...]'`.
    private static func literal(in text: NSString, at offset: Int) -> String? {
        let length = text.length
        guard offset < length else { return nil }
        if text.character(at: offset) == SqlLexer.singleQuote {
            return quotedBody(in: text, from: offset + 1)
        }
        guard let span = SqlLexer.skipAlternativeQuotedString(text, at: offset, length: length) else { return nil }
        let prefixLength = text.character(at: offset) == SqlLexer.smallQ
            || text.character(at: offset) == SqlLexer.capitalQ ? 3 : 4
        let bodyStart = offset + prefixLength
        let bodyEnd = max(bodyStart, span.next - 2)
        return text.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
    }

    private static func quotedBody(in text: NSString, from start: Int) -> String {
        let length = text.length
        var cursor = start
        while cursor < length {
            if text.character(at: cursor) == SqlLexer.singleQuote {
                guard cursor + 1 < length, text.character(at: cursor + 1) == SqlLexer.singleQuote else { break }
                cursor += 2
                continue
            }
            cursor += 1
        }
        return text.substring(with: NSRange(location: start, length: cursor - start))
            .replacingOccurrences(of: "''", with: "'")
    }

    private static func deletesWithoutWhere(_ segment: String) -> Bool {
        guard let keyword = firstKeyword(in: segment, deleteWordRegex) else { return false }
        let tail = " \((segment as NSString).substring(from: keyword.location)) "
        return whereWordRegex?.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length)) == nil
    }
}
