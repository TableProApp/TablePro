import Foundation

/// The DynamoDB actions the editor accepts as `<Action> {request JSON}`.
enum DynamoDBOperation: String, CaseIterable, Sendable {
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

    var target: String { "DynamoDB_20120810.\(rawValue)" }

    init?(caseInsensitive name: String) {
        guard let match = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        self = match
    }

    var isRead: Bool {
        switch self {
        case .scan, .query, .getItem, .batchGetItem, .transactGetItems, .describeTable, .listTables,
             .describeTimeToLive, .describeContinuousBackups, .listTagsOfResource, .describeLimits:
            return true
        default:
            return false
        }
    }

    var changesCatalog: Bool {
        self == .createTable || self == .updateTable || self == .deleteTable
    }
}

struct DynamoDBOrderTerm: Sendable, Equatable {
    let attribute: String
    let descending: Bool
}

/// The part of a read the grid, an export or a header click adds after the request itself.
/// `LIMIT` and `OFFSET` count the items returned, after every filter, not the items DynamoDB read.
struct DynamoDBReadWindow: Sendable, Equatable {
    var order: [DynamoDBOrderTerm] = []
    var limit: Int?
    var offset: Int = 0

    var isEmpty: Bool { order.isEmpty && limit == nil && offset == 0 }

    var text: String {
        var parts: [String] = []
        if !order.isEmpty {
            let terms = order.map { "\(DynamoDBStatement.quote($0.attribute))\($0.descending ? " DESC" : " ASC")" }
            parts.append("ORDER BY " + terms.joined(separator: ", "))
        }
        if let limit { parts.append("LIMIT \(limit)") }
        if offset > 0 { parts.append("OFFSET \(offset)") }
        return parts.joined(separator: " ")
    }
}

struct DynamoDBAPICall: Sendable, Equatable {
    let operation: DynamoDBOperation
    let body: DynamoDBJSON
}

enum DynamoDBStatement: Sendable, Equatable {
    case partiQL(text: String, window: DynamoDBReadWindow)
    case apiCall(DynamoDBAPICall, window: DynamoDBReadWindow)
    case browse(DynamoDBBrowseRequest, window: DynamoDBReadWindow)

    static let browseVerb = "Browse"

    static func parse(_ raw: String) throws -> DynamoDBStatement {
        let text = trimmed(raw)
        let verb = String(text.prefix { $0.isLetter })
        let afterVerb = text.dropFirst(verb.count).drop(while: \.isWhitespace)
        guard !verb.isEmpty, afterVerb.first == "{" else { return try partiQL(text) }

        let parsed: (value: DynamoDBJSON, remainder: String)
        do {
            parsed = try DynamoDBJSON.parsePrefix(String(afterVerb))
        } catch {
            throw DynamoDBError.invalidStatement(
                String(format: String(localized: "The %1$@ request is not valid JSON: %2$@"), verb, error.localizedDescription)
            )
        }
        guard case .object = parsed.value else {
            throw DynamoDBError.invalidStatement(
                String(format: String(localized: "The %@ request must be a JSON object"), verb)
            )
        }
        let window = try parseWindow(parsed.remainder, verb: verb)

        if verb.caseInsensitiveCompare(browseVerb) == .orderedSame {
            return .browse(try DynamoDBBrowseRequest(json: parsed.value), window: window)
        }
        guard let operation = DynamoDBOperation(caseInsensitive: verb) else {
            throw DynamoDBError.invalidStatement(
                String(format: String(localized: "\"%@\" is not a DynamoDB action this editor runs"), verb)
            )
        }
        guard window.isEmpty || operation == .scan || operation == .query else {
            throw DynamoDBError.invalidStatement(
                String(format: String(localized: "%@ takes no ORDER BY, LIMIT or OFFSET"), operation.rawValue)
            )
        }
        return .apiCall(DynamoDBAPICall(operation: operation, body: parsed.value), window: window)
    }

    var text: String {
        switch self {
        case .partiQL(let text, let window):
            return window.isEmpty ? text : "\(text)\n\(window.text)"
        case .apiCall(let call, let window):
            let base = "\(call.operation.rawValue) \(call.body.serialized())"
            return window.isEmpty ? base : "\(base) \(window.text)"
        case .browse(let request, let window):
            let base = "\(Self.browseVerb) \(request.json.serialized())"
            return window.isEmpty ? base : "\(base) \(window.text)"
        }
    }

    static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - Parsing helpers

    private static func trimmed(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func partiQL(_ text: String) throws -> DynamoDBStatement {
        let split = DynamoDBPartiQL.splitTrailingWindow(text)
        return .partiQL(text: split.statement, window: split.window)
    }

    static func parseWindow(_ remainder: String, verb: String) throws -> DynamoDBReadWindow {
        var tokens = DynamoDBPartiQL.tokens(of: remainder)
        var window = DynamoDBReadWindow()
        func unexpected() -> DynamoDBError {
            let rest = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            return .invalidStatement(
                String(format: String(localized: "Unexpected text after the %1$@ request: %2$@"), verb, rest)
            )
        }
        if tokens.first?.isKeyword("ORDER") == true {
            guard tokens.count >= 3, tokens[1].isKeyword("BY") else { throw unexpected() }
            tokens.removeFirst(2)
            while true {
                guard let identifier = tokens.first?.identifierValue else { throw unexpected() }
                tokens.removeFirst()
                var descending = false
                if tokens.first?.isKeyword("DESC") == true {
                    descending = true
                    tokens.removeFirst()
                } else if tokens.first?.isKeyword("ASC") == true {
                    tokens.removeFirst()
                }
                window.order.append(DynamoDBOrderTerm(attribute: identifier, descending: descending))
                guard tokens.first?.text == "," else { break }
                tokens.removeFirst()
            }
        }
        if tokens.first?.isKeyword("LIMIT") == true {
            guard tokens.count >= 2, let limit = Int(tokens[1].text), limit >= 0 else { throw unexpected() }
            window.limit = limit
            tokens.removeFirst(2)
        }
        if tokens.first?.isKeyword("OFFSET") == true {
            guard tokens.count >= 2, let offset = Int(tokens[1].text), offset >= 0 else { throw unexpected() }
            window.offset = offset
            tokens.removeFirst(2)
        }
        guard tokens.isEmpty else { throw unexpected() }
        return window
    }
}
