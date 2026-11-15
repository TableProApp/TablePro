//
//  OracleObjectQueries.swift
//  OracleDriverPlugin
//
//  Catalog SQL for routines and triggers. Pure, so it is testable without a server.
//

import Foundation
import TableProSQLQuoting

// Every dictionary view is named with its `SYS` owner: an unqualified name resolves to a current-schema object before
// the public synonym, so a planted same-named view would be read. The rule is `OracleDictionary`'s in TableProOracleCore,
// written out here because a target compiling this file does not link that package.
nonisolated public enum OracleObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        SQLQuoting.stringLiteralBody(value)
    }

    public static func quoteIdentifier(_ value: String) -> String {
        SQLQuoting.identifier(value)
    }

    // Oracle's grammar is `COMMENT ON TABLE [schema.]{table | view}`: there is no `VIEW` keyword.
    public static func commentStatement(qualifiedName: String, objectType: String, comment: String?) -> String? {
        let keyword: String
        switch objectType.uppercased() {
        case "TABLE", "PARTITIONED TABLE", "VIEW": keyword = "TABLE"
        case "MATERIALIZED VIEW": keyword = "MATERIALIZED VIEW"
        default: return nil
        }
        return "COMMENT ON \(keyword) \(qualifiedName) IS \(commentLiteral(comment))"
    }

    public static func columnCommentStatement(qualifiedTable: String, column: String, comment: String?) -> String {
        "COMMENT ON COLUMN \(qualifiedTable).\(quoteIdentifier(column)) IS \(commentLiteral(comment))"
    }

    // Oracle removes a comment only when it is set to the empty string.
    private static func commentLiteral(_ comment: String?) -> String {
        SQLQuoting.stringLiteral(comment ?? "")
    }

    // Standalone routines only: a packaged one is read through its package, so its row would have no source. No
    // argument list: only a package overloads, and the LISTAGG that builds one raises ORA-01489 past 4000 bytes.
    public static func routineList(schema: String) -> String {
        let schemaLiteral = escapeLiteral(schema)
        return """
            SELECT
                o.OBJECT_NAME,
                o.OWNER,
                o.OBJECT_TYPE,
                o.STATUS
            FROM SYS.ALL_OBJECTS o
            WHERE o.OWNER = '\(schemaLiteral)'
              AND o.OBJECT_TYPE IN ('PROCEDURE', 'FUNCTION')
            ORDER BY o.OBJECT_TYPE, o.OBJECT_NAME
            """
    }

    // ALL_SOURCE, one row per line, in LINE order. DBMS_METADATA.GET_DDL returns nothing rather than raising without
    // SELECT_CATALOG_ROLE for another schema, which reads as a routine that vanished.
    public static func routineSource(schema: String, name: String, type: String) -> String {
        """
        SELECT TEXT
        FROM SYS.ALL_SOURCE
        WHERE OWNER = '\(escapeLiteral(schema))'
          AND NAME = '\(escapeLiteral(name))'
          AND TYPE = '\(escapeLiteral(type))'
        ORDER BY LINE
        """
    }

    // TRIGGER_BODY stays last because it is a LONG.
    public static func triggerList(schema: String, table: String?) -> String {
        let schemaLiteral = escapeLiteral(schema)
        // A schema browse reads OWNER, a per-table fetch TABLE_OWNER and TABLE_NAME: they differ for a trigger one
        // schema owns on another schema's table.
        let scope = table.map {
            "TABLE_OWNER = '\(schemaLiteral)' AND TABLE_NAME = '\(escapeLiteral($0))'"
        } ?? "OWNER = '\(schemaLiteral)'"
        return """
            SELECT
                TRIGGER_NAME,
                TABLE_NAME,
                OWNER,
                TRIGGER_TYPE,
                TRIGGERING_EVENT,
                STATUS,
                WHEN_CLAUSE,
                DESCRIPTION,
                ACTION_TYPE,
                TABLE_OWNER,
                TRIGGER_BODY
            FROM SYS.ALL_TRIGGERS
            WHERE \(scope)
            ORDER BY TABLE_NAME, TRIGGER_NAME
            """
    }

    public static func timing(fromTriggerType triggerType: String) -> String {
        let upper = triggerType.uppercased()
        if upper.contains("INSTEAD OF") { return "INSTEAD OF" }
        if upper.hasPrefix("BEFORE") { return "BEFORE" }
        return "AFTER"
    }

    public static func orientation(fromTriggerType triggerType: String) -> String {
        triggerType.uppercased().contains("EACH ROW") ? "ROW" : "STATEMENT"
    }

    // Measured on 23ai: DESCRIPTION holds the header up to the body but neither the WHEN clause nor DISABLE, and a CALL
    // trigger's TRIGGER_BODY holds only the call's target with a `;` Oracle added, so those are written back here or the
    // trigger fails with ORA-04079. The owner's schema is taken out of the header, as ALL_SOURCE gives a procedure, so
    // the trigger lands in the schema the statement runs in. Not for a trigger on another schema's table, which is
    // replayed from that schema, where only the owner's qualifier still names it.
    public static func triggerDefinition(_ trigger: OracleTriggerSource) -> String {
        let prefix = "CREATE OR REPLACE TRIGGER "
        let body = triggerBody(trigger)
        guard let description = nonEmpty(trigger.description) else {
            guard let body else { return "" }
            return "\(prefix)\(quoteIdentifier(trigger.name))\n\(body)"
        }
        let header = trigger.owner.flatMap { owner in
            owner == trigger.tableOwner ? strippingSchema(owner, from: description) : nil
        } ?? description
        var lines = [prefix + header]
        if nonEmpty(trigger.status)?.uppercased() == "DISABLED" {
            lines.append("DISABLE")
        }
        if let condition = nonEmpty(trigger.whenClause) {
            lines.append("WHEN (\(condition))")
        }
        if let body {
            lines.append(body)
        }
        return lines.joined(separator: "\n")
    }

    // `probe.t`, `"PROBE"."T"` and `PROBE.SCHEMA` all lose their `PROBE.`: Oracle folds an unquoted name to upper case,
    // and a quoted one matches exactly. Comments and literals are copied as they are.
    public static func strippingSchema(_ schema: String, from header: String) -> String {
        var reader = OracleHeaderScanner(header)
        var output = ""
        while let token = reader.next() {
            guard case .identifier(let name, let quoted) = token.kind,
                  !token.followsPeriod,
                  quoted ? name == schema : name.uppercased() == schema,
                  let resume = reader.positionAfterPeriod(from: token.end)
            else {
                output += token.text
                continue
            }
            reader.move(to: resume)
        }
        return output
    }

    private static func triggerBody(_ trigger: OracleTriggerSource) -> String? {
        guard let body = nonEmpty(trigger.body) else { return nil }
        guard nonEmpty(trigger.actionType)?.uppercased() == "CALL" else { return body }
        var target = body
        if target.hasSuffix(";") {
            target = String(target.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "CALL \(target)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

// One ALL_TRIGGERS row, as `OracleObjectQueries.triggerList(schema:table:)` selects it.
nonisolated public struct OracleTriggerSource: Sendable, Equatable {
    public let name: String
    public let owner: String?
    public let tableOwner: String?
    public let description: String?
    public let whenClause: String?
    public let actionType: String?
    public let status: String?
    public let body: String?

    public init(
        name: String,
        owner: String?,
        tableOwner: String?,
        description: String?,
        whenClause: String?,
        actionType: String?,
        status: String?,
        body: String?
    ) {
        self.name = name
        self.owner = owner
        self.tableOwner = tableOwner
        self.description = description
        self.whenClause = whenClause
        self.actionType = actionType
        self.status = status
        self.body = body
    }
}

// Each token keeps the exact text it covers, so the header is written back unchanged around what is taken out.
nonisolated private struct OracleHeaderScanner {
    enum Kind {
        case identifier(String, quoted: Bool)
        case other
    }

    struct Token {
        let kind: Kind
        let text: String
        let end: Int
        let followsPeriod: Bool
    }

    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var lastSignificant: Unicode.Scalar?

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    mutating func move(to position: Int) {
        index = position
        lastSignificant = "."
    }

    mutating func next() -> Token? {
        guard index < scalars.count else { return nil }
        let start = index
        let followsPeriod = lastSignificant == "."
        let kind = readToken()
        let text = String(String.UnicodeScalarView(scalars[start..<index]))
        if let last = scalars[start..<index].last, !last.properties.isWhitespace, !isTrivia(at: start) {
            lastSignificant = last
        }
        return Token(kind: kind, text: text, end: index, followsPeriod: followsPeriod)
    }

    // Where the name after a `.` starts, when the token ending at `position` is followed by one.
    func positionAfterPeriod(from position: Int) -> Int? {
        var cursor = skippingWhitespace(from: position)
        guard cursor < scalars.count, scalars[cursor] == "." else { return nil }
        cursor = skippingWhitespace(from: cursor + 1)
        guard cursor < scalars.count, scalars[cursor] == "\"" || Self.isWordScalar(scalars[cursor]) else {
            return nil
        }
        return cursor
    }

    private mutating func readToken() -> Kind {
        let scalar = scalars[index]
        if scalar == "-", peek(1) == "-" {
            while index < scalars.count, scalars[index] != "\n" { index += 1 }
            return .other
        }
        if scalar == "/", peek(1) == "*" {
            index += 2
            while index < scalars.count, !(scalars[index] == "*" && peek(1) == "/") { index += 1 }
            index = min(index + 2, scalars.count)
            return .other
        }
        if scalar == "'" {
            skipQuoted(by: "'")
            return .other
        }
        if scalar == "\"" {
            let name = readQuotedIdentifier()
            return .identifier(name, quoted: true)
        }
        if Self.isWordScalar(scalar) {
            let start = index
            while index < scalars.count, Self.isWordScalar(scalars[index]) { index += 1 }
            return .identifier(String(String.UnicodeScalarView(scalars[start..<index])), quoted: false)
        }
        index += 1
        return .other
    }

    private mutating func readQuotedIdentifier() -> String {
        var name = String.UnicodeScalarView()
        index += 1
        while index < scalars.count {
            if scalars[index] == "\"" {
                guard peek(1) == "\"" else {
                    index += 1
                    return String(name)
                }
                name.append("\"")
                index += 2
                continue
            }
            name.append(scalars[index])
            index += 1
        }
        return String(name)
    }

    private mutating func skipQuoted(by quote: Unicode.Scalar) {
        index += 1
        while index < scalars.count {
            if scalars[index] == quote {
                guard peek(1) == quote else {
                    index += 1
                    return
                }
                index += 2
                continue
            }
            index += 1
        }
    }

    private func isTrivia(at position: Int) -> Bool {
        let scalar = scalars[position]
        if scalar == "-", position + 1 < scalars.count, scalars[position + 1] == "-" { return true }
        return scalar == "/" && position + 1 < scalars.count && scalars[position + 1] == "*"
    }

    private func skippingWhitespace(from position: Int) -> Int {
        var cursor = position
        while cursor < scalars.count, scalars[cursor].properties.isWhitespace { cursor += 1 }
        return cursor
    }

    private func peek(_ offset: Int) -> Unicode.Scalar? {
        let position = index + offset
        return position < scalars.count ? scalars[position] : nil
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "$" || scalar == "#"
    }
}
