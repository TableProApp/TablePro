import Foundation

/// A stored PL/SQL unit a `CREATE` statement defines, read from the statement's header.
///
/// Oracle answers a `CREATE PROCEDURE` whose body does not compile with success: the object is stored INVALID and the
/// failure travels only as a warning flag, which the driver drops. The errors are in `ALL_ERRORS`, keyed by owner,
/// name and type, so reporting them takes knowing which unit the statement defined.
public struct OraclePLSQLUnit: Sendable, Equatable {
    /// The type as `ALL_ERRORS.TYPE` spells it, such as `PACKAGE BODY`.
    public let type: String

    /// The schema the header names, or nil when the unit is created in the session's current schema.
    public let owner: String?
    public let name: String

    public init(type: String, owner: String?, name: String) {
        self.type = type
        self.owner = owner
        self.name = name
    }

    private static let modifiers: Set<String> = ["OR", "REPLACE", "EDITIONABLE", "NONEDITIONABLE"]
    private static let unitTypes: Set<String> = ["PROCEDURE", "FUNCTION", "PACKAGE", "TRIGGER", "TYPE"]

    /// The unit `sql` creates, or nil when it creates something else or nothing at all.
    public static func definition(in sql: String) -> OraclePLSQLUnit? {
        var reader = HeaderReader(sql)
        guard reader.nextWord() == "CREATE" else { return nil }
        var word = reader.nextWord()
        while let modifier = word, modifiers.contains(modifier) {
            word = reader.nextWord()
        }
        guard let kind = word, unitTypes.contains(kind) else { return nil }
        var type = kind
        if kind == "PACKAGE" || kind == "TYPE", reader.peekWord() == "BODY" {
            _ = reader.nextWord()
            type = "\(kind) BODY"
        }
        if reader.peekWord() == "IF" {
            _ = reader.nextWord()
            guard reader.nextWord() == "NOT", reader.nextWord() == "EXISTS" else { return nil }
        }
        guard let first = reader.nextIdentifier() else { return nil }
        guard reader.consumePeriod() else {
            return OraclePLSQLUnit(type: type, owner: nil, name: first)
        }
        guard let second = reader.nextIdentifier() else { return nil }
        return OraclePLSQLUnit(type: type, owner: first, name: second)
    }

    /// Whether `sql` is an anonymous block, which opens with `DECLARE` or `BEGIN` after any `<<label>>`.
    ///
    /// The driver reports a row count of 1 for every block it runs, which is not a number of rows anything changed.
    public static func isAnonymousBlock(_ sql: String) -> Bool {
        var reader = HeaderReader(sql)
        reader.skipLabels()
        let word = reader.nextWord()
        return word == "DECLARE" || word == "BEGIN"
    }

    /// The compilation errors Oracle recorded for this unit, most recent compile only, in the order it reported them.
    ///
    /// Warnings are left out: with `PLSQL_WARNINGS` enabled Oracle records them against units that compiled.
    public var errorsQuery: String {
        let owner = owner.map { "'\(OracleSchemaQueries.escapeLiteral($0))'" }
            ?? "SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')"
        return """
            SELECT LINE, POSITION, TEXT FROM ALL_ERRORS \
            WHERE OWNER = \(owner) \
            AND NAME = '\(OracleSchemaQueries.escapeLiteral(name))' \
            AND TYPE = '\(OracleSchemaQueries.escapeLiteral(type))' \
            AND ATTRIBUTE = 'ERROR' \
            ORDER BY SEQUENCE
            """
    }

    /// What the editor shows for a unit that was stored but does not compile, one error per line.
    public func compilationFailureMessage(errors: [OracleCompilationError]) -> String {
        let header = String(
            format: String(localized: "%1$@ %2$@ was created with compilation errors:"),
            type, name
        )
        let lines = errors.map { error in
            String(
                format: String(localized: "Line %1$lld, column %2$lld: %3$@"),
                Int64(error.line), Int64(error.position), error.text
            )
        }
        return ([header] + lines).joined(separator: "\n")
    }
}

public struct OracleCompilationError: Sendable, Equatable {
    public let line: Int
    public let position: Int
    public let text: String

    public init(line: Int, position: Int, text: String) {
        self.line = line
        self.position = position
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads one `ALL_ERRORS` row as ``OraclePLSQLUnit/errorsQuery`` selects it.
    public init?(row: [OracleRawCell]) {
        guard row.count >= 3,
              let line = row[0].stringValue.flatMap(Int.init),
              let position = row[1].stringValue.flatMap(Int.init),
              let text = row[2].stringValue
        else {
            return nil
        }
        self.init(line: line, position: position, text: text)
    }
}

/// Reads the words and identifiers at the head of a statement, past comments.
struct HeaderReader {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ sql: String) {
        scalars = Array(sql.unicodeScalars)
    }

    mutating func nextWord() -> String? {
        skipTrivia()
        let start = index
        while index < scalars.count, Self.isWordScalar(scalars[index]) {
            index += 1
        }
        guard index > start else { return nil }
        return String(String.UnicodeScalarView(scalars[start..<index])).uppercased()
    }

    func peekWord() -> String? {
        var copy = self
        return copy.nextWord()
    }

    /// A quoted identifier keeps its case; an unquoted one is stored uppercased, as Oracle stores it.
    mutating func nextIdentifier() -> String? {
        skipTrivia()
        guard index < scalars.count else { return nil }
        guard scalars[index] == "\"" else { return nextWord() }
        var name = String.UnicodeScalarView()
        index += 1
        while index < scalars.count {
            if scalars[index] == "\"" {
                guard index + 1 < scalars.count, scalars[index + 1] == "\"" else {
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
        return nil
    }

    mutating func skipLabels() {
        while true {
            skipTrivia()
            guard index + 1 < scalars.count, scalars[index] == "<", scalars[index + 1] == "<" else { return }
            index += 2
            while index + 1 < scalars.count, !(scalars[index] == ">" && scalars[index + 1] == ">") {
                index += 1
            }
            index = min(index + 2, scalars.count)
        }
    }

    mutating func consumePeriod() -> Bool {
        skipTrivia()
        guard index < scalars.count, scalars[index] == "." else { return false }
        index += 1
        return true
    }

    private mutating func skipTrivia() {
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.properties.isWhitespace {
                index += 1
                continue
            }
            if scalar == "-", index + 1 < scalars.count, scalars[index + 1] == "-" {
                while index < scalars.count, scalars[index] != "\n" {
                    index += 1
                }
                continue
            }
            if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                index += 2
                while index + 1 < scalars.count, !(scalars[index] == "*" && scalars[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, scalars.count)
                continue
            }
            return
        }
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "$"
            || scalar == "#"
    }
}
