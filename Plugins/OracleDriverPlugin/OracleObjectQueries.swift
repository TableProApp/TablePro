//
//  OracleObjectQueries.swift
//  OracleDriverPlugin
//
//  Catalog SQL for routines and triggers. Pure, so it is testable without a server.
//

import Foundation

/// Catalog SQL for routines and triggers. Pure, so it is testable without a server.
///
/// Every dictionary view is named with its `SYS` owner. Oracle resolves an unqualified name to a current-schema object
/// before the public synonym, so a user who owns the schema the reader is in could plant a same-named table or view and
/// have the app read it. The rule and its measurement live in `OracleDictionary` in TableProOracleCore, which this file
/// cannot import: it compiles into the test target, which does not link that package, so the prefix is written out here.
public enum OracleObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    public static func quoteIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Standalone procedures and functions only. A packaged routine is addressed through its
    /// package, which is a different object with a different DDL call, so listing it here would
    /// produce rows whose source cannot be fetched.
    /// Standalone procedures and functions only. A packaged routine is addressed through its
    /// package, which is a different object with a different DDL call, so listing it here would
    /// produce rows whose source cannot be fetched.
    ///
    /// No argument list is built. Oracle only allows overloading inside a package, so a standalone
    /// routine is identified by its name alone, and the LISTAGG that would assemble a signature
    /// raises ORA-01489 past 4000 bytes, which fails the whole listing over one wide signature.
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

    /// ALL_SOURCE stores one row per line, so the body has to be reassembled in LINE order.
    /// DBMS_METADATA.GET_DDL is nicer but returns nothing rather than raising when the caller
    /// lacks SELECT_CATALOG_ROLE for another schema, which reads as a routine that vanished.
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

    /// TRIGGER_BODY is the part the previous query never selected, which left the viewer showing a
    /// CREATE OR REPLACE header with no body under it. It stays last because it is a LONG.
    public static func triggerList(schema: String, table: String?) -> String {
        let schemaLiteral = escapeLiteral(schema)
        /// A schema browse asks for the triggers this schema owns, which is OWNER. A per-table
        /// fetch asks for the triggers on that table, which is TABLE_OWNER plus TABLE_NAME. They
        /// differ for a trigger one schema owns on another schema's table.
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

    /// The statement that recreates a trigger, assembled from the columns ALL_TRIGGERS splits it into.
    ///
    /// DESCRIPTION holds the header up to the body: the name, timing, events, subject, REFERENCING,
    /// FOR EACH ROW and FOLLOWS. Measured on Oracle 23ai, it holds neither the WHEN clause nor
    /// DISABLE, and a trigger whose body is a CALL keeps only the call's target in TRIGGER_BODY,
    /// with no CALL keyword and a `;` Oracle added. Written back as they were read, the WHEN clause
    /// and the disabled state were lost and a CALL trigger failed with ORA-04079, after the sync had
    /// already dropped the one in the target.
    ///
    /// The owner's own schema is taken out of the header, the way ALL_SOURCE already gives a
    /// procedure without it, so the trigger lands in whatever schema the statement runs in rather
    /// than going back to the one it was read from. That holds only for a trigger on its own
    /// schema's table, or on the schema itself: one schema's trigger on another's table is listed
    /// with that table and replayed from its schema, where only the owner's qualifier still names
    /// the same trigger. A qualifier naming any other schema stays.
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

    /// `DROP TRIGGER`, qualified when the trigger lives outside the session's current schema. An
    /// unqualified name is looked up in the current schema, so a trigger another schema owns was
    /// dropped under the wrong owner or not found. A trigger in the current schema stays unqualified,
    /// which keeps a dump restorable into a schema of another name.
    public static func dropTrigger(name: String, schema: String?, currentSchema: String?) -> String {
        guard let schema = nonEmpty(schema), schema != currentSchema else {
            return "DROP TRIGGER \(quoteIdentifier(name))"
        }
        return "DROP TRIGGER \(quoteIdentifier(schema)).\(quoteIdentifier(name))"
    }

    /// `header` with every qualifier that names `schema` taken out: `probe.t`, `"PROBE"."T"` and
    /// `PROBE.SCHEMA` all lose their `PROBE.`. An unquoted name matches however it is cased, since
    /// Oracle folds it to upper case; a quoted one matches exactly. Comments and literals are copied
    /// as they are.
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

/// One ALL_TRIGGERS row, as ``OracleObjectQueries/triggerList(schema:table:)`` selects it.
public struct OracleTriggerSource: Sendable, Equatable {
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

/// Reads a trigger header one token at a time: identifiers, quoted identifiers, comments, literals
/// and single characters, each with the exact text it covers so the header can be written back
/// unchanged around what is taken out.
private struct OracleHeaderScanner {
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

    /// Where the name after a `.` starts, when the token ending at `position` is followed by one.
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
