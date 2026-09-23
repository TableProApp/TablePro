//
//  DynamoDBRequestStatement.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

/// The DynamoDB API actions the driver runs from the editor as `<Action> {request JSON}`, plus the `Browse` request a
/// table tab sends. The driver matches the name ignoring case, and so does this.
enum DynamoDBRequestAction: String, CaseIterable, Sendable {
    case browse = "Browse"
    case scan = "Scan"
    case query = "Query"
    case getItem = "GetItem"
    case batchGetItem = "BatchGetItem"
    case transactGetItems = "TransactGetItems"
    case describeTable = "DescribeTable"
    case listTables = "ListTables"
    case describeTimeToLive = "DescribeTimeToLive"
    case describeContinuousBackups = "DescribeContinuousBackups"
    case listTagsOfResource = "ListTagsOfResource"
    case describeLimits = "DescribeLimits"
    case putItem = "PutItem"
    case updateItem = "UpdateItem"
    case deleteItem = "DeleteItem"
    case batchWriteItem = "BatchWriteItem"
    case transactWriteItems = "TransactWriteItems"
    case executeStatement = "ExecuteStatement"
    case executeTransaction = "ExecuteTransaction"
    case batchExecuteStatement = "BatchExecuteStatement"
    case createTable = "CreateTable"
    case updateTable = "UpdateTable"
    case deleteTable = "DeleteTable"
    case updateTimeToLive = "UpdateTimeToLive"
    case updateContinuousBackups = "UpdateContinuousBackups"
    case tagResource = "TagResource"
    case untagResource = "UntagResource"

    init?(named name: String) {
        guard let match = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        self = match
    }

    var changesCatalog: Bool {
        self == .createTable || self == .updateTable || self == .deleteTable
    }

    /// The member listing the PartiQL entries a request runs, each naming its text under `Statement`.
    var partiQLListKey: String? {
        switch self {
        case .executeTransaction: return "TransactStatements"
        case .batchExecuteStatement: return "Statements"
        default: return nil
        }
    }
}

/// A statement in the request form, `<Action> {request JSON}`, read the way the driver reads it: a word of letters
/// and then a JSON object, with a read window allowed after it. Anything else is PartiQL.
struct DynamoDBRequestStatement: Sendable, Equatable {
    let actionName: String
    let body: DynamoDBRequestJSON?
    let trailingText: String

    init?(_ statement: String) {
        let text = StatementBlank.trimming(QueryClassifier.strippingLeadingComments(statement))
        let verb = text.prefix { $0.isLetter }
        guard !verb.isEmpty else { return nil }
        let afterVerb = text[verb.endIndex...].drop { $0.isWhitespace }
        guard afterVerb.first == "{" else { return nil }
        actionName = String(verb)
        let parsed = DynamoDBRequestJSON.parsePrefix(afterVerb)
        body = parsed?.value
        trailingText = parsed?.remainder ?? ""
    }

    var action: DynamoDBRequestAction? {
        DynamoDBRequestAction(named: actionName)
    }

    /// The PartiQL a request runs, or nil when it runs none. An entry with no statement text of its own is left
    /// out, so a caller has to compare against ``partiQLEntryCount`` before trusting the list is whole.
    var partiQLStatements: [String]? {
        guard let action, let body else { return nil }
        if action == .executeStatement {
            return body.values(forKey: "Statement").compactMap(\.stringValue)
        }
        guard let listKey = action.partiQLListKey else { return nil }
        return partiQLEntries(of: body, listKey: listKey).flatMap { entry in
            entry.values(forKey: "Statement").compactMap(\.stringValue)
        }
    }

    var partiQLEntryCount: Int {
        guard let action, let body else { return 0 }
        if action == .executeStatement {
            return body.hasMember("Statement") ? 1 : 0
        }
        guard let listKey = action.partiQLListKey else { return 0 }
        return partiQLEntries(of: body, listKey: listKey).count
    }

    /// Whether nothing follows the JSON but the `ORDER BY`, `LIMIT` and `OFFSET` the driver accepts after a read.
    var hasOnlyReadWindowAfterBody: Bool {
        DynamoDBReadWindowText.isReadWindow(trailingText)
    }

    private func partiQLEntries(of body: DynamoDBRequestJSON, listKey: String) -> [DynamoDBRequestJSON] {
        body.values(forKey: listKey).flatMap(\.elements)
    }
}

/// The clause the driver takes after a read request: `ORDER BY "a" [ASC|DESC], ...`, then `LIMIT n`, then
/// `OFFSET m`, each optional, with comments and a trailing semicolon allowed.
enum DynamoDBReadWindowText {
    static func isReadWindow(_ text: String) -> Bool {
        guard var tokens = tokens(of: text) else { return false }
        if tokens.first?.isKeyword("ORDER") == true {
            guard tokens.count >= 3, tokens[1].isKeyword("BY") else { return false }
            tokens.removeFirst(2)
            guard consumeOrderTerms(&tokens) else { return false }
        }
        consumeCount(after: "LIMIT", in: &tokens)
        consumeCount(after: "OFFSET", in: &tokens)
        return tokens.isEmpty
    }

    private struct Token {
        enum Kind {
            case word
            case quotedIdentifier
            case number
            case comma
        }

        let kind: Kind
        let text: String

        func isKeyword(_ keyword: String) -> Bool {
            kind == .word && text.caseInsensitiveCompare(keyword) == .orderedSame
        }

        var isIdentifier: Bool {
            kind == .quotedIdentifier || kind == .word
        }
    }

    private static func consumeOrderTerms(_ tokens: inout [Token]) -> Bool {
        while true {
            guard let term = tokens.first, term.isIdentifier else { return false }
            tokens.removeFirst()
            if tokens.first?.isKeyword("ASC") == true || tokens.first?.isKeyword("DESC") == true {
                tokens.removeFirst()
            }
            guard tokens.first?.kind == .comma else { return true }
            tokens.removeFirst()
        }
    }

    private static func consumeCount(after keyword: String, in tokens: inout [Token]) {
        guard tokens.count >= 2, tokens[0].isKeyword(keyword), tokens[1].kind == .number else { return }
        tokens.removeFirst(2)
    }

    private static func tokens(of text: String) -> [Token]? {
        var tokens: [Token] = []
        var remaining = Substring(text)
        while true {
            remaining = remaining.drop { $0.isWhitespace || $0 == ";" }
            guard let first = remaining.first else { return tokens }
            if remaining.hasPrefix("--") {
                remaining = remaining.drop { !$0.isNewline }
                continue
            }
            if remaining.hasPrefix("/*") {
                guard let close = remaining.range(of: "*/") else { return tokens }
                remaining = remaining[close.upperBound...]
                continue
            }
            if first == "," {
                tokens.append(Token(kind: .comma, text: ","))
                remaining = remaining.dropFirst()
                continue
            }
            if first == "\"" {
                guard let quoted = quotedIdentifier(in: remaining) else { return nil }
                tokens.append(Token(kind: .quotedIdentifier, text: quoted.identifier))
                remaining = quoted.rest
                continue
            }
            if first.isNumber {
                let digits = remaining.prefix { $0.isNumber }
                tokens.append(Token(kind: .number, text: String(digits)))
                remaining = remaining.dropFirst(digits.count)
                continue
            }
            guard first.isLetter || first == "_" else { return nil }
            let word = remaining.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            tokens.append(Token(kind: .word, text: String(word)))
            remaining = remaining.dropFirst(word.count)
        }
    }

    private static func quotedIdentifier(in text: Substring) -> (identifier: String, rest: Substring)? {
        var identifier = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            guard character == "\"" else {
                identifier.append(character)
                continue
            }
            guard index < text.endIndex, text[index] == "\"" else { return (identifier, text[index...]) }
            identifier.append("\"")
            index = text.index(after: index)
        }
        return nil
    }
}
