import Foundation

/// What a statement the grammar accepted does: every call in order, and every key its literals spell.
public struct MongoStatement: Equatable, Sendable {
    public struct Call: Equatable, Sendable {
        public let name: String
        public let isRead: Bool
        /// The first key of a `runCommand` or `adminCommand` document, which names the command.
        public let commandName: String?
    }

    public var calls: [Call] = []
    public var objectKeys: Set<String> = []
}

/// Accepts one mongosh statement whose arguments are literal data, and nothing else.
///
/// Rejecting is always safe, since the caller then treats the statement as a write. Accepting has
/// to mean JavaScriptCore reads the text the same way, so the lexical rules for whitespace,
/// comments, strings, numbers and regular expression literals follow ECMAScript exactly, and
/// anything they would read differently is refused: escapes in identifiers, legacy octal, `?.`,
/// template literals, a second statement.
public struct MongoStatementParser {
    private struct Rejected: Error {}

    private enum Receiver {
        case database, client, collection, cursor, explainer, value
    }

    /// Deep enough for any real filter, shallow enough that a crafted `[[[...]]]` cannot exhaust the stack.
    private static let maximumDepth = 64

    private static let databaseReads: Set<String> = [
        "getCollectionNames", "getCollectionInfos", "stats", "version", "serverStatus", "hostInfo",
        "currentOp", "getName"
    ]

    private static let collectionReads: Set<String> = [
        "findOne", "count", "countDocuments", "estimatedDocumentCount", "distinct", "getIndexes",
        "getIndices", "stats", "dataSize", "storageSize", "totalIndexSize", "totalSize", "isCapped",
        "getName", "getFullName"
    ]

    private static let cursorModifiers: Set<String> = [
        "sort", "projection", "collation", "hint", "limit", "skip", "batchSize", "maxTimeMS",
        "allowDiskUse", "pretty"
    ]

    private static let cursorReads: Set<String> = [
        "toArray", "itcount", "size", "count", "next", "hasNext", "tryNext", "isExhausted",
        "objsLeftInBatch", "explain"
    ]

    private static let explainedReads: Set<String> = ["find", "aggregate", "count"]

    private static let commandMethods: Set<String> = ["runCommand", "adminCommand"]

    /// Pure value constructors from the shell prelude. None of them reaches the server.
    private static let constructors: Set<String> = [
        "ObjectId", "ISODate", "Date", "NumberLong", "NumberInt", "NumberDecimal", "Int32", "Long",
        "Decimal128", "Double", "Timestamp", "BinData", "HexData", "UUID", "LegacyJavaUUID",
        "LegacyCSharpUUID", "LegacyPythonUUID", "JUUID", "CSUUID", "NUUID", "PYUUID", "LUUID",
        "BSONRegExp", "BSONSymbol", "DBRef"
    ]

    /// Non-writable globals, so no earlier statement can rebind them.
    private static let numericConstants: Set<String> = ["NaN", "Infinity"]

    private static let boundaryKeys: Set<String> = ["MinKey", "MaxKey"]

    private static let shownTopics: Set<String> = ["dbs", "databases", "collections", "tables"]

    private static let regularExpressionFlags: Set<Unicode.Scalar> = ["d", "g", "i", "m", "s", "u", "v", "y"]

    private let scalars: String.UnicodeScalarView
    private var index: String.UnicodeScalarView.Index
    private var depth = 0
    private var statement = MongoStatement()
    private let shadowsCollection: (String) -> Bool

    private init(_ text: String, shadowsCollection: @escaping (String) -> Bool = { _ in false }) {
        scalars = text.unicodeScalars
        index = scalars.startIndex
        self.shadowsCollection = shadowsCollection
    }

    /// Whitespace and comments only, as JavaScript reads them: a `--` line is a decrement, not a comment.
    public static func isTrivia(_ text: String) -> Bool {
        var parser = MongoStatementParser(text)
        guard (try? parser.skipTrivia()) != nil else { return false }
        return parser.index == parser.scalars.endIndex
    }

    // `shadowsCollection` names what `db.<name>` reaches instead of a collection: PluginKit's
    // MongoCollectionAccessor.isShadowedByDatabaseMember, which this module cannot import.
    public static func parse(_ text: String, shadowsCollection: @escaping (String) -> Bool) -> MongoStatement? {
        if isShellCommand(text) { return MongoStatement() }
        var parser = MongoStatementParser(text, shadowsCollection: shadowsCollection)
        return try? parser.statementText()
    }

    /// `use orders` and `show collections`, in exactly the shape the driver rewrites into a call
    /// (`MongoShellCommandLine.rewrite`): anything looser reaches JavaScriptCore as typed.
    public static func isShellCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        for keyword in ["use", "show"] where lowered.hasPrefix(keyword + " ") {
            let remainder = trimmed.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
            let word = remainder.hasSuffix(";") ? String(remainder.dropLast()) : remainder
            guard keyword == "use" else { return shownTopics.contains(word.lowercased()) }
            return !word.isEmpty && word.unicodeScalars.allSatisfy(isDatabaseNameScalar)
        }
        return false
    }

    private static func isDatabaseNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-")
    }

    // MARK: - Statement

    private mutating func statementText() throws -> MongoStatement {
        try skipTrivia()
        guard try identifier() == "db" else { throw Rejected() }
        var receiver = Receiver.database
        while let member = try memberName() {
            try skipTrivia()
            receiver = try step(from: receiver, member: member, isCall: peek() == "(")
        }
        if peek() == ";" {
            advance()
            try skipTrivia()
        }
        guard index == scalars.endIndex else { throw Rejected() }
        return statement
    }

    /// `.name` or `["name"]`, with trivia allowed around the dot as JavaScript allows it.
    private mutating func memberName() throws -> String? {
        try skipTrivia()
        switch peek() {
        case ".":
            advance()
            try skipTrivia()
            return try identifier()
        case "[":
            advance()
            try skipTrivia()
            let name = try string()
            try skipTrivia()
            try expect("]")
            return name
        default:
            return nil
        }
    }

    private mutating func step(from receiver: Receiver, member: String, isCall: Bool) throws -> Receiver {
        switch receiver {
        case .database:
            guard isCall else {
                guard !shadowsCollection(member) else { throw Rejected() }
                return .collection
            }
            switch member {
            case "getSiblingDB":
                try stringArgument()
                return .database
            case "getCollection":
                try stringArgument()
                return .collection
            case "getMongo":
                try call(member, isRead: true)
                return .client
            default:
                try call(member, isRead: Self.databaseReads.contains(member))
                return .value
            }
        case .client:
            guard isCall, member == "getDB" else { throw Rejected() }
            try stringArgument()
            return .database
        case .collection:
            guard isCall else { throw Rejected() }
            switch member {
            case "find", "aggregate":
                try call(member, isRead: true)
                return .cursor
            case "explain":
                try call(member, isRead: true)
                return .explainer
            default:
                try call(member, isRead: Self.collectionReads.contains(member))
                return .value
            }
        case .cursor:
            guard isCall else { throw Rejected() }
            let modifies = Self.cursorModifiers.contains(member)
            try call(member, isRead: modifies || Self.cursorReads.contains(member))
            return modifies ? .cursor : .value
        case .explainer:
            guard isCall else { throw Rejected() }
            try call(member, isRead: Self.explainedReads.contains(member))
            return .value
        case .value:
            throw Rejected()
        }
    }

    private mutating func call(_ name: String, isRead: Bool) throws {
        let firstKey = try arguments()
        let commandName = Self.commandMethods.contains(name) ? firstKey : nil
        statement.calls.append(MongoStatement.Call(name: name, isRead: isRead, commandName: commandName))
    }

    private mutating func stringArgument() throws {
        try expect("(")
        try skipTrivia()
        _ = try string()
        try skipTrivia()
        try expect(")")
    }

    /// The literal arguments of a call. Returns the first key of the first argument when it is a document.
    private mutating func arguments() throws -> String? {
        try expect("(")
        try skipTrivia()
        var firstKey: String?
        var isFirst = true
        while peek() != ")" {
            let key = try value()
            if isFirst {
                firstKey = key
                isFirst = false
            }
            try skipTrivia()
            guard peek() == "," else { break }
            advance()
            try skipTrivia()
        }
        try expect(")")
        return firstKey
    }

    // MARK: - Literals

    /// One literal value. Returns its first key when it is a document.
    private mutating func value() throws -> String? {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maximumDepth else { throw Rejected() }
        try skipTrivia()
        guard let scalar = peek() else { throw Rejected() }
        switch scalar {
        case "{":
            return try document()
        case "[":
            try array()
        case "\"", "'":
            _ = try string()
        case "/":
            try regularExpression()
        case "-", ".", "0"..."9":
            try number()
        default:
            try word()
        }
        return nil
    }

    private mutating func document() throws -> String? {
        try expect("{")
        try skipTrivia()
        var firstKey: String?
        while peek() != "}" {
            let key = try propertyKey()
            // A literal's `__proto__` key sets its prototype rather than a field.
            guard key != "__proto__" else { throw Rejected() }
            statement.objectKeys.insert(key)
            if firstKey == nil { firstKey = key }
            try skipTrivia()
            try expect(":")
            _ = try value()
            try skipTrivia()
            guard peek() == "," else { break }
            advance()
            try skipTrivia()
        }
        try expect("}")
        return firstKey
    }

    private mutating func propertyKey() throws -> String {
        switch peek() {
        case "\"", "'":
            return try string()
        case let scalar? where ("0"..."9").contains(scalar):
            let start = index
            try number()
            return String(String.UnicodeScalarView(scalars[start..<index]))
        default:
            return try identifier()
        }
    }

    private mutating func array() throws {
        try expect("[")
        try skipTrivia()
        while peek() != "]" {
            _ = try value()
            try skipTrivia()
            guard peek() == "," else { break }
            advance()
            try skipTrivia()
        }
        try expect("]")
    }

    /// `true`, `false`, `null`, a prelude constructor called on literals, or `MinKey`/`MaxKey`.
    private mutating func word() throws {
        var name = try identifier()
        if Self.numericConstants.contains(name) { return }
        switch name {
        case "true", "false", "null":
            return
        case "new":
            try skipTrivia()
            name = try identifier()
            guard Self.constructors.contains(name) else { throw Rejected() }
        default:
            if Self.boundaryKeys.contains(name) {
                try skipTrivia()
                if peek() == "(" {
                    try expect("(")
                    try skipTrivia()
                    try expect(")")
                }
                return
            }
            guard Self.constructors.contains(name) else { throw Rejected() }
        }
        try skipTrivia()
        _ = try arguments()
    }

    private mutating func string() throws -> String {
        guard let quote = peek(), quote == "\"" || quote == "'" else { throw Rejected() }
        advance()
        var decoded = String.UnicodeScalarView()
        while let scalar = peek() {
            advance()
            if scalar == quote { return String(decoded) }
            if scalar == "\\" {
                try escape(into: &decoded)
                continue
            }
            guard scalar != "\n", scalar != "\r" else { throw Rejected() }
            decoded.append(scalar)
        }
        throw Rejected()
    }

    private mutating func escape(into decoded: inout String.UnicodeScalarView) throws {
        guard let scalar = peek() else { throw Rejected() }
        advance()
        switch scalar {
        case "n": decoded.append("\n")
        case "t": decoded.append("\t")
        case "r": decoded.append("\r")
        case "b": decoded.append("\u{08}")
        case "f": decoded.append("\u{0C}")
        case "v": decoded.append("\u{0B}")
        case "0":
            // `\0` followed by a digit is a legacy octal escape.
            if let next = peek(), ("0"..."9").contains(next) { throw Rejected() }
            decoded.append("\u{00}")
        case "1"..."9":
            throw Rejected()
        case "x":
            decoded.append(try decodedScalar(hexDigits(count: 2)))
        case "u":
            decoded.append(try unicodeEscape())
        case "\r":
            if peek() == "\n" { advance() }
        case "\n", "\u{2028}", "\u{2029}":
            break
        default:
            decoded.append(scalar)
        }
    }

    private mutating func unicodeEscape() throws -> Unicode.Scalar {
        let value: UInt32
        if peek() == "{" {
            advance()
            var digits = ""
            while let next = peek(), next != "}" {
                digits.unicodeScalars.append(next)
                advance()
            }
            try expect("}")
            guard !digits.isEmpty, let parsed = UInt32(digits, radix: 16) else { throw Rejected() }
            value = parsed
        } else {
            value = try hexDigits(count: 4)
        }
        guard (0xD800...0xDBFF).contains(value) else { return try decodedScalar(value) }
        // A high surrogate only stands for a character together with the `\u` low surrogate after it.
        try expect("\\")
        try expect("u")
        let low = try hexDigits(count: 4)
        guard (0xDC00...0xDFFF).contains(low) else { throw Rejected() }
        return try decodedScalar(0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00))
    }

    private mutating func hexDigits(count: Int) throws -> UInt32 {
        var digits = ""
        for _ in 0..<count {
            guard let next = peek(), next.properties.isASCIIHexDigit else { throw Rejected() }
            digits.unicodeScalars.append(next)
            advance()
        }
        guard let value = UInt32(digits, radix: 16) else { throw Rejected() }
        return value
    }

    private func decodedScalar(_ value: UInt32) throws -> Unicode.Scalar {
        guard let scalar = Unicode.Scalar(value) else { throw Rejected() }
        return scalar
    }

    /// A decimal literal, optionally negated. Hex, octal, binary, BigInt and separators are refused.
    private mutating func number() throws {
        if peek() == "-" {
            advance()
            if peek() == "I" {
                guard try identifier() == "Infinity" else { throw Rejected() }
                return
            }
        }
        let integerStart = index
        let integerDigits = digits()
        if integerDigits > 1, scalars[integerStart] == "0" { throw Rejected() }
        if peek() == "." {
            advance()
            guard digits() > 0 || integerDigits > 0 else { throw Rejected() }
        } else if integerDigits == 0 {
            throw Rejected()
        }
        if peek() == "e" || peek() == "E" {
            advance()
            if peek() == "+" || peek() == "-" { advance() }
            guard digits() > 0 else { throw Rejected() }
        }
        if let next = peek(), next == "\\" || isIdentifierPart(next) { throw Rejected() }
    }

    private mutating func digits() -> Int {
        var count = 0
        while let next = peek(), ("0"..."9").contains(next) {
            advance()
            count += 1
        }
        return count
    }

    /// The lexical grammar of a regular expression literal: a `/` inside a class does not end it.
    private mutating func regularExpression() throws {
        try expect("/")
        var inClass = false
        var isEmpty = true
        while let scalar = peek() {
            advance()
            guard !isLineTerminator(scalar) else { throw Rejected() }
            switch scalar {
            case "\\":
                guard let next = peek(), !isLineTerminator(next) else { throw Rejected() }
                advance()
            case "[":
                inClass = true
            case "]":
                inClass = false
            case "/" where !inClass:
                guard !isEmpty else { throw Rejected() }
                while let flag = peek(), Self.regularExpressionFlags.contains(flag) { advance() }
                if let next = peek(), next == "\\" || isIdentifierPart(next) || !next.isASCII && !isTrivia(next) {
                    throw Rejected()
                }
                return
            case "*" where isEmpty:
                throw Rejected()
            default:
                break
            }
            isEmpty = false
        }
        throw Rejected()
    }

    // MARK: - Lexing

    /// An ASCII identifier. One followed by `\` or by a non-ASCII character JavaScript might read as
    /// part of the name is refused, since the name the parser saw would not be the name that runs.
    private mutating func identifier() throws -> String {
        guard let first = peek(), isIdentifierStart(first) else { throw Rejected() }
        var name = String.UnicodeScalarView()
        while let next = peek(), isIdentifierPart(next) {
            name.append(next)
            advance()
        }
        if let next = peek(), next == "\\" || !next.isASCII && !isTrivia(next) { throw Rejected() }
        return String(name)
    }

    private func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || scalar == "_" || scalar == "$")
    }

    private func isIdentifierPart(_ scalar: Unicode.Scalar) -> Bool {
        isIdentifierStart(scalar) || ("0"..."9").contains(scalar)
    }

    /// ECMAScript WhiteSpace and LineTerminator, and comments. An unterminated block comment is refused.
    private mutating func skipTrivia() throws {
        while let scalar = peek() {
            if isTrivia(scalar) {
                advance()
                continue
            }
            guard scalar == "/", let next = peek(offset: 1) else { return }
            if next == "/" {
                while let inside = peek(), !isLineTerminator(inside) { advance() }
            } else if next == "*" {
                advance()
                advance()
                var closed = false
                while let inside = peek() {
                    advance()
                    if inside == "*", peek() == "/" {
                        advance()
                        closed = true
                        break
                    }
                }
                guard closed else { throw Rejected() }
            } else {
                return
            }
        }
    }

    private func isTrivia(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\t", "\u{0B}", "\u{0C}", " ", "\u{A0}", "\u{FEFF}":
            return true
        default:
            return isLineTerminator(scalar) || scalar.properties.generalCategory == .spaceSeparator
        }
    }

    private func isLineTerminator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}"
    }

    private func peek(offset: Int = 0) -> Unicode.Scalar? {
        var cursor = index
        for _ in 0..<offset {
            guard cursor < scalars.endIndex else { return nil }
            cursor = scalars.index(after: cursor)
        }
        return cursor < scalars.endIndex ? scalars[cursor] : nil
    }

    private mutating func advance() {
        guard index < scalars.endIndex else { return }
        index = scalars.index(after: index)
    }

    private mutating func expect(_ scalar: Unicode.Scalar) throws {
        guard peek() == scalar else { throw Rejected() }
        advance()
    }
}
