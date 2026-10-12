import Foundation

struct DynamoDBPartiQLToken: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case word
        case quotedIdentifier
        case string
        case number
        case parameter
        case symbol
    }

    let kind: Kind
    /// The source spelling for words, numbers and symbols; the unescaped content for quoted
    /// identifiers and string literals.
    let text: String
    let range: Range<String.Index>
    let depth: Int

    func isKeyword(_ keyword: String) -> Bool {
        kind == .word && text.caseInsensitiveCompare(keyword) == .orderedSame
    }

    var identifierValue: String? {
        switch kind {
        case .word, .quotedIdentifier: return text
        default: return nil
        }
    }
}

enum DynamoDBPartiQL {
    enum Kind: Equatable {
        case select
        case insert
        case update
        case delete
        case other
    }

    /// What a `?` stands for, read from the words around it.
    enum ParameterRole: Equatable {
        case assigned(DynamoDBAttributePath)
        case compared(DynamoDBAttributePath)
        case inserted(String)
        case unknown
    }

    static func kind(of statement: String) -> Kind {
        let first = tokens(of: statement).first
        if first?.isKeyword("SELECT") == true { return .select }
        if first?.isKeyword("INSERT") == true { return .insert }
        if first?.isKeyword("UPDATE") == true { return .update }
        if first?.isKeyword("DELETE") == true { return .delete }
        return .other
    }

    /// The table and, for `"Table"."Index"`, the index a statement names.
    static func target(of statement: String) -> (table: String, index: String?)? {
        let tokens = tokens(of: statement)
        guard let first = tokens.first else { return nil }
        let nameStart: Int?
        if first.isKeyword("SELECT") || first.isKeyword("DELETE") {
            nameStart = tokens.firstIndex { $0.isKeyword("FROM") && $0.depth == 0 }.map { $0 + 1 }
        } else if first.isKeyword("INSERT") {
            nameStart = tokens.firstIndex { $0.isKeyword("INTO") }.map { $0 + 1 }
        } else if first.isKeyword("UPDATE") {
            nameStart = 1
        } else {
            nameStart = nil
        }
        guard let start = nameStart, start < tokens.count, let table = tokens[start].identifierValue else {
            return nil
        }
        if start + 2 < tokens.count, tokens[start + 1].text == ".", let index = tokens[start + 2].identifierValue {
            return (table, index)
        }
        return (table, nil)
    }

    static func hasReturning(_ statement: String) -> Bool {
        tokens(of: statement).contains { $0.depth == 0 && $0.isKeyword("RETURNING") }
    }

    /// Whether the WHERE clause pins the top-level `attribute` with `=`, or with `IN` when
    /// `acceptsIn`, in a term every row must satisfy: one joined to the rest by AND alone, at the
    /// top level or inside parentheses, and never negated. That is what lets DynamoDB answer a SELECT
    /// with a Query rather than a Scan; its ORDER BY needs the `=` form, because with `IN` it orders
    /// each partition on its own.
    static func whereFixes(_ attribute: String, in statement: String, acceptsIn: Bool = true) -> Bool {
        let tokens = tokens(of: statement)
        guard let whereIndex = tokens.firstIndex(where: { $0.depth == 0 && $0.isKeyword("WHERE") }) else {
            return false
        }
        let clause = Array(tokens[(whereIndex + 1)...])
        let clauseEnd = clause.firstIndex { $0.depth == 0 && ($0.isKeyword("ORDER") || $0.isKeyword("RETURNING")) }
            ?? clause.count
        let condition = Array(clause[..<clauseEnd])
        var openers: [Int] = []
        for (offset, token) in condition.enumerated() {
            if token.kind == .symbol, ["(", "[", "{"].contains(token.text) {
                openers.append(offset)
                continue
            }
            if token.kind == .symbol, [")", "]", "}"].contains(token.text) {
                _ = openers.popLast()
                continue
            }
            guard token.identifierValue == attribute,
                  pinsTerm(at: offset, in: condition, acceptsIn: acceptsIn),
                  isRequired(openers: openers, in: condition)
            else { continue }
            return true
        }
        return false
    }

    /// `attribute = …` or `attribute IN …` on the top-level attribute, not negated.
    private static func pinsTerm(at offset: Int, in condition: [DynamoDBPartiQLToken], acceptsIn: Bool) -> Bool {
        guard offset + 1 < condition.count else { return false }
        let next = condition[offset + 1]
        if offset > 0 {
            let previous = condition[offset - 1]
            if previous.text == "." || previous.isKeyword("NOT") { return false }
        }
        if next.text == "." || next.text == "[" { return false }
        return next.text == "=" || (acceptsIn && next.isKeyword("IN"))
    }

    /// Whether every group around a term is a plain parenthesized condition, neither negated nor a
    /// function's arguments, and no level from the term out to the WHERE clause holds an OR.
    private static func isRequired(openers: [Int], in condition: [DynamoDBPartiQLToken]) -> Bool {
        for opener in openers {
            guard condition[opener].text == "(" else { return false }
            guard opener > 0 else { continue }
            let before = condition[opener - 1]
            if before.isKeyword("NOT") || before.kind == .quotedIdentifier { return false }
            if before.kind == .word, !before.isKeyword("AND"), !before.isKeyword("OR") { return false }
        }
        if condition.contains(where: { $0.depth == 0 && $0.isKeyword("OR") }) { return false }
        for opener in openers {
            let innerDepth = condition[opener].depth + 1
            let closer = condition[(opener + 1)...].firstIndex { token in
                token.kind == .symbol && token.text == ")" && token.depth == condition[opener].depth
            } ?? condition.count
            let group = condition[(opener + 1)..<closer]
            if group.contains(where: { $0.depth == innerDepth && $0.isKeyword("OR") }) { return false }
        }
        return true
    }

    /// A SELECT's trailing `ORDER BY`, `LIMIT` and `OFFSET`, separated from the statement.
    ///
    /// DynamoDB's PartiQL has no `LIMIT` or `OFFSET` at all, and it accepts `ORDER BY` only on the
    /// sort key of a partition the WHERE clause fixes. The app appends all three: a column header
    /// click, an export's row limit, a compare. The driver applies them itself instead.
    static func splitTrailingWindow(_ statement: String) -> (statement: String, window: DynamoDBReadWindow) {
        guard kind(of: statement) == .select else { return (statement, DynamoDBReadWindow()) }
        var tokens = tokens(of: statement).filter { $0.depth == 0 }
        var window = DynamoDBReadWindow()
        var cut = statement.endIndex

        if tokens.count >= 2, tokens[tokens.count - 2].isKeyword("OFFSET"),
           let offset = Int(tokens.last?.text ?? ""), offset >= 0 {
            window.offset = offset
            cut = tokens[tokens.count - 2].range.lowerBound
            tokens.removeLast(2)
        }
        if tokens.count >= 2, tokens[tokens.count - 2].isKeyword("LIMIT"),
           let limit = Int(tokens.last?.text ?? ""), limit >= 0 {
            window.limit = limit
            cut = tokens[tokens.count - 2].range.lowerBound
            tokens.removeLast(2)
        }
        if let orderIndex = trailingOrderByIndex(tokens) {
            var terms: [DynamoDBOrderTerm] = []
            var cursor = orderIndex + 2
            while cursor < tokens.count, let attribute = tokens[cursor].identifierValue {
                cursor += 1
                var descending = false
                if cursor < tokens.count, tokens[cursor].isKeyword("DESC") {
                    descending = true
                    cursor += 1
                } else if cursor < tokens.count, tokens[cursor].isKeyword("ASC") {
                    cursor += 1
                }
                terms.append(DynamoDBOrderTerm(attribute: attribute, descending: descending))
                guard cursor < tokens.count, tokens[cursor].text == "," else { break }
                cursor += 1
            }
            if cursor == tokens.count, !terms.isEmpty {
                window.order = terms
                cut = tokens[orderIndex].range.lowerBound
            }
        }
        let remaining = String(statement[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (remaining, window)
    }

    private static func trailingOrderByIndex(_ tokens: [DynamoDBPartiQLToken]) -> Int? {
        guard let index = tokens.lastIndex(where: { $0.isKeyword("ORDER") }),
              index + 1 < tokens.count, tokens[index + 1].isKeyword("BY")
        else { return nil }
        return index
    }

    /// The role of each `?` in `statement`, in order.
    /// The top-level attribute names an INSERT's `VALUE {...}` sets, whether the value is a literal
    /// or a `?`.
    static func insertedAttributes(in statement: String) -> Set<String> {
        let tokens = tokens(of: statement)
        guard let valueIndex = tokens.firstIndex(where: { $0.depth == 0 && $0.isKeyword("VALUE") }) else { return [] }
        var names = Set<String>()
        for index in tokens.indices where index > valueIndex && index + 1 < tokens.count {
            let token = tokens[index]
            guard token.kind == .string, token.depth == 1, tokens[index + 1].text == ":" else { continue }
            names.insert(token.text)
        }
        return names
    }

    static func parameterRoles(in statement: String) -> [ParameterRole] {
        let tokens = tokens(of: statement)
        var roles: [ParameterRole] = []
        var clause = ""
        var comparedPath: DynamoDBAttributePath?
        var pendingKey: String?

        for (index, token) in tokens.enumerated() {
            if token.kind == .word, token.depth == 0 {
                let upper = token.text.uppercased()
                if ["SET", "WHERE", "VALUE", "REMOVE", "RETURNING", "FROM", "INTO"].contains(upper) {
                    clause = upper
                }
            }
            switch token.kind {
            case .string where clause == "VALUE":
                if index + 1 < tokens.count, tokens[index + 1].text == ":" {
                    pendingKey = token.text
                }
            case .word, .quotedIdentifier:
                let isOperatorWord = ["AND", "OR", "NOT", "IN", "BETWEEN", "IS"].contains(token.text.uppercased())
                if !isOperatorWord || token.kind == .quotedIdentifier {
                    if index + 1 < tokens.count, tokens[index + 1].text != "(" {
                        comparedPath = path(tokens, endingAt: index)
                    }
                }
            case .parameter:
                if clause == "VALUE", let key = pendingKey {
                    roles.append(.inserted(key))
                    pendingKey = nil
                } else if clause == "SET", let path = comparedPath {
                    roles.append(.assigned(path))
                } else if let path = comparedPath {
                    roles.append(.compared(path))
                } else {
                    roles.append(.unknown)
                }
            default:
                break
            }
        }
        return roles
    }

    /// The document path, such as `"a"."b"[0]`, whose last name ends at `index`, followed by any
    /// list indexes after it.
    private static func path(_ tokens: [DynamoDBPartiQLToken], endingAt index: Int) -> DynamoDBAttributePath? {
        var cursor = index
        while cursor >= 2, tokens[cursor - 1].text == ".", tokens[cursor - 2].identifierValue != nil {
            cursor -= 2
        }
        var segments: [DynamoDBAttributePath.Segment] = []
        var position = cursor
        while position <= index {
            if let name = tokens[position].identifierValue {
                segments.append(.name(name))
            }
            position += 2
        }
        var trailing = index + 1
        while trailing + 2 < tokens.count, tokens[trailing].text == "[", tokens[trailing + 2].text == "]",
              let element = Int(tokens[trailing + 1].text), element >= 0 {
            segments.append(.index(element))
            trailing += 3
        }
        return segments.isEmpty ? nil : DynamoDBAttributePath(segments: segments)
    }

    // MARK: - Tokenizer

    static func tokens(of text: String) -> [DynamoDBPartiQLToken] {
        var tokens: [DynamoDBPartiQLToken] = []
        var index = text.startIndex
        var depth = 0

        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                index = text.index(after: index)
                continue
            }
            if text[index...].hasPrefix("--") {
                index = text[index...].firstIndex(where: \.isNewline) ?? text.endIndex
                continue
            }
            if text[index...].hasPrefix("/*") {
                let bodyStart = text.index(index, offsetBy: 2)
                index = text[bodyStart...].range(of: "*/")?.upperBound ?? text.endIndex
                continue
            }
            let start = index
            switch character {
            case "\"", "'":
                let (content, end) = quoted(text, from: index, quote: character)
                tokens.append(DynamoDBPartiQLToken(
                    kind: character == "\"" ? .quotedIdentifier : .string,
                    text: content, range: start..<end, depth: depth
                ))
                index = end
            case "?":
                index = text.index(after: index)
                tokens.append(DynamoDBPartiQLToken(kind: .parameter, text: "?", range: start..<index, depth: depth))
            case "(", "[", "{":
                index = text.index(after: index)
                tokens.append(DynamoDBPartiQLToken(kind: .symbol, text: String(character), range: start..<index, depth: depth))
                depth += 1
            case ")", "]", "}":
                depth = max(0, depth - 1)
                index = text.index(after: index)
                tokens.append(DynamoDBPartiQLToken(kind: .symbol, text: String(character), range: start..<index, depth: depth))
            default:
                if character.isLetter || character == "_" {
                    let end = text[index...].firstIndex { !($0.isLetter || $0.isNumber || $0 == "_") } ?? text.endIndex
                    tokens.append(DynamoDBPartiQLToken(
                        kind: .word, text: String(text[index..<end]), range: start..<end, depth: depth
                    ))
                    index = end
                } else if character.isNumber || (character == "-" && nextIsDigit(text, after: index)) {
                    var end = text.index(after: index)
                    while end < text.endIndex {
                        let current = text[end]
                        let previous = text[text.index(before: end)]
                        let isExponentSign = (current == "+" || current == "-") && (previous == "e" || previous == "E")
                        guard current.isNumber || current == "." || current == "e" || current == "E" || isExponentSign
                        else { break }
                        end = text.index(after: end)
                    }
                    tokens.append(DynamoDBPartiQLToken(
                        kind: .number, text: String(text[index..<end]), range: start..<end, depth: depth
                    ))
                    index = end
                } else {
                    let end = symbolEnd(text, from: index)
                    tokens.append(DynamoDBPartiQLToken(
                        kind: .symbol, text: String(text[index..<end]), range: start..<end, depth: depth
                    ))
                    index = end
                }
            }
        }
        return tokens
    }

    private static func quoted(_ text: String, from start: String.Index, quote: Character) -> (String, String.Index) {
        var content = ""
        var index = text.index(after: start)
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == quote {
                if next < text.endIndex, text[next] == quote {
                    content.append(quote)
                    index = text.index(after: next)
                    continue
                }
                return (content, next)
            }
            content.append(character)
            index = next
        }
        return (content, text.endIndex)
    }

    private static func nextIsDigit(_ text: String, after index: String.Index) -> Bool {
        let next = text.index(after: index)
        return next < text.endIndex && text[next].isNumber
    }

    private static func symbolEnd(_ text: String, from index: String.Index) -> String.Index {
        let pairs = ["<>", "<=", ">=", "!=", "<<", ">>"]
        for pair in pairs where text[index...].hasPrefix(pair) {
            return text.index(index, offsetBy: 2)
        }
        return text.index(after: index)
    }
}
