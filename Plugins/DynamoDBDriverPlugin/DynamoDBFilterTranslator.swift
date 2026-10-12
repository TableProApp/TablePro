import Foundation

/// A condition DynamoDB cannot evaluate, applied to the items it returns: `ENDS WITH`, a regular
/// expression, a match that ignores case, and a search across every attribute.
struct DynamoDBClientPredicate: Sendable, Equatable {
    let path: DynamoDBAttributePath?
    let op: String
    let value: String
    let secondValue: String?
    let caseSensitive: Bool

    func matches(_ item: DynamoDBItem) -> Bool {
        guard let path else {
            return item.values.contains { matches(value: $0) }
        }
        return matches(value: path.value(in: item))
    }

    private func matches(value attribute: DynamoDBAttributeValue?) -> Bool {
        switch op {
        case "IS NULL":
            return attribute == nil || attribute == .null
        case "IS NOT NULL":
            return attribute != nil && attribute != .null
        default:
            break
        }
        guard let attribute else { return false }
        let text = DynamoDBCellCodec.displayText(for: attribute)
        let subject = caseSensitive ? text : text.lowercased()
        let needle = caseSensitive ? value : value.lowercased()
        switch op {
        case "=": return Self.equal(subject, needle, attribute)
        case "!=", "<>": return !Self.equal(subject, needle, attribute)
        case "CONTAINS": return contains(attribute)
        case "NOT CONTAINS": return !contains(attribute)
        case "STARTS WITH": return startsWith(attribute)
        case "ENDS WITH": return subject.hasSuffix(needle)
        case "IS EMPTY": return text.isEmpty
        case "IS NOT EMPTY": return !text.isEmpty
        case "IN":
            return Self.listItems(value).contains { Self.equal(subject, caseSensitive ? $0 : $0.lowercased(), attribute) }
        case "NOT IN":
            return !Self.listItems(value).contains { Self.equal(subject, caseSensitive ? $0 : $0.lowercased(), attribute) }
        case "REGEX": return regexMatches(text)
        case ">", ">=", "<", "<=": return compares(text, op: op)
        case "BETWEEN":
            guard let bounds = DynamoDBFilterTranslator.bounds(value: value, secondValue: secondValue) else {
                return false
            }
            return Self.order(text, bounds.lower) != .orderedAscending
                && Self.order(text, bounds.upper) != .orderedDescending
        default:
            return false
        }
    }

    private func fold(_ text: String) -> String {
        caseSensitive ? text : text.lowercased()
    }

    /// DynamoDB's `contains`: text inside a String, or a member of a set or a list. A Number, a
    /// Boolean, a Map and Binary never contain the filter's text, so the result is the same
    /// whichever side runs the filter.
    private func contains(_ attribute: DynamoDBAttributeValue) -> Bool {
        let needle = fold(value)
        switch attribute {
        case .string(let text):
            return fold(text).contains(needle)
        case .stringSet(let members):
            return members.contains { fold($0) == needle }
        case .numberSet(let members):
            return DynamoDBNumber.isValid(value) && members.contains { DynamoDBNumber.areEqual($0, value) }
        case .list(let elements):
            return elements.contains { element in
                switch element {
                case .string(let text): return fold(text) == needle
                case .number(let text): return DynamoDBNumber.isValid(value) && DynamoDBNumber.areEqual(text, value)
                default: return false
                }
            }
        default:
            return false
        }
    }

    /// DynamoDB's `begins_with`, which only a String answers for text.
    private func startsWith(_ attribute: DynamoDBAttributeValue) -> Bool {
        guard case .string(let text) = attribute else { return false }
        return fold(text).hasPrefix(fold(value))
    }

    private static func equal(_ subject: String, _ needle: String, _ attribute: DynamoDBAttributeValue) -> Bool {
        if case .number = attribute, DynamoDBNumber.isValid(subject), DynamoDBNumber.isValid(needle) {
            return DynamoDBNumber.areEqual(subject, needle)
        }
        return subject == needle
    }

    private func regexMatches(_ text: String) -> Bool {
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: value, options: options) else { return false }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private func compares(_ text: String, op: String) -> Bool {
        let order = Self.order(text, value)
        switch op {
        case ">": return order == .orderedDescending
        case ">=": return order != .orderedAscending
        case "<": return order == .orderedAscending
        default: return order != .orderedDescending
        }
    }

    static func order(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if DynamoDBNumber.isValid(lhs), DynamoDBNumber.isValid(rhs) {
            return DynamoDBNumber.compare(lhs, rhs)
        }
        return lhs < rhs ? .orderedAscending : (lhs == rhs ? .orderedSame : .orderedDescending)
    }

    static func listItems(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Turns one grid filter into a FilterExpression term, a key condition, or a client predicate.
struct DynamoDBFilterTranslator {
    enum Outcome: Equatable {
        case server(String)
        case client(DynamoDBClientPredicate)
        /// The filter can match no item: a Number key compared with text that is not a number.
        case never
    }

    static let rawFilterColumn = "__RAW__"
    static let anyAttributeColumn = "*"

    static let keyConditionOperators: Set<String> = ["=", "<", "<=", ">", ">=", "BETWEEN", "STARTS WITH"]

    let schema: DynamoDBTableSchema

    static func unsupportedReason(for filter: DynamoDBBrowseFilter) -> String? {
        guard filter.attribute == rawFilterColumn else { return nil }
        return String(localized: "Raw filters aren't available for DynamoDB. Write the condition in PartiQL in the editor.")
    }

    func translate(
        _ filter: DynamoDBBrowseFilter,
        path: DynamoDBAttributePath?,
        context: inout DynamoDBExpressionContext
    ) -> Outcome {
        guard let path else { return .client(clientPredicate(filter, path: nil)) }
        if needsClient(filter) { return .client(clientPredicate(filter, path: path)) }

        let candidates = { (text: String) in self.candidates(for: path, text: text, kind: filter.kind) }
        let rendered = context.path(path)

        switch filter.op {
        case "IS NULL":
            let nullType = context.value(.string("NULL"), hint: "null")
            return .server("(attribute_not_exists(\(rendered)) OR attribute_type(\(rendered), \(nullType)))")
        case "IS NOT NULL":
            let nullType = context.value(.string("NULL"), hint: "null")
            return .server("(attribute_exists(\(rendered)) AND NOT attribute_type(\(rendered), \(nullType)))")
        case "IS EMPTY":
            let empty = context.value(.string(""), hint: "empty")
            return .server("\(rendered) = \(empty)")
        case "IS NOT EMPTY":
            let empty = context.value(.string(""), hint: "empty")
            return .server("(attribute_exists(\(rendered)) AND \(rendered) <> \(empty))")
        case "=", ">", ">=", "<", "<=":
            let values = candidates(filter.value).filter { filter.op == "=" || $0.type != .boolean }
            guard !values.isEmpty else { return .never }
            let terms = values.map { "\(rendered) \(filter.op) \(context.value($0, hint: path.root))" }
            return .server(Self.any(terms))
        case "!=", "<>":
            let values = candidates(filter.value)
            let terms = values.map { "\(rendered) <> \(context.value($0, hint: path.root))" }
            return .server(Self.all(["attribute_exists(\(rendered))"] + terms))
        case "CONTAINS", "NOT CONTAINS":
            let values = containsCandidates(filter.value, path: path)
            let terms = values.map { "contains(\(rendered), \(context.value($0, hint: path.root)))" }
            let contained = Self.any(terms)
            guard filter.op == "NOT CONTAINS" else { return .server(contained) }
            return .server("(attribute_exists(\(rendered)) AND NOT \(contained))")
        case "STARTS WITH":
            let keyType = schema.keyType(of: path.root)
            guard path.isTopLevel == false || keyType == nil || keyType == .string || keyType == .binary else {
                return .never
            }
            let prefix = context.value(.string(filter.value), hint: path.root)
            return .server("begins_with(\(rendered), \(prefix))")
        case "ENDS WITH", "REGEX":
            return .client(clientPredicate(filter, path: path))
        case "IN", "NOT IN":
            let values = DynamoDBClientPredicate.listItems(filter.value).flatMap(candidates)
            guard !values.isEmpty else { return filter.op == "IN" ? .never : .server("attribute_exists(\(rendered))") }
            let placeholders = values.map { context.value($0, hint: path.root) }
            let chunks = stride(from: 0, to: placeholders.count, by: 100).map {
                "\(rendered) IN (\(placeholders[$0..<min($0 + 100, placeholders.count)].joined(separator: ", ")))"
            }
            let membership = Self.any(chunks)
            guard filter.op == "NOT IN" else { return .server(membership) }
            return .server("(attribute_exists(\(rendered)) AND NOT \(membership))")
        case "BETWEEN":
            guard let bounds = Self.bounds(value: filter.value, secondValue: filter.secondValue) else { return .never }
            let uppers = candidates(bounds.upper)
            let pairs = candidates(bounds.lower).compactMap { lower in
                uppers.first { $0.type == lower.type }.map { (lower, $0) }
            }
            let terms = pairs.compactMap { lower, upper -> String? in
                guard lower.type != .boolean else { return nil }
                if lower.type == .number, DynamoDBNumber.compare(bounds.lower, bounds.upper) == .orderedDescending {
                    return nil
                }
                if lower.type == .string, bounds.lower > bounds.upper { return nil }
                let lowerPlaceholder = context.value(lower, hint: path.root)
                let upperPlaceholder = context.value(upper, hint: path.root)
                return "\(rendered) BETWEEN \(lowerPlaceholder) AND \(upperPlaceholder)"
            }
            guard !terms.isEmpty else { return .never }
            return .server(Self.any(terms))
        default:
            return .client(clientPredicate(filter, path: path))
        }
    }

    /// A key condition term for a key attribute of the access path, typed by the table's schema.
    func keyCondition(
        _ filter: DynamoDBBrowseFilter,
        attribute: String,
        context: inout DynamoDBExpressionContext
    ) -> String? {
        guard let type = schema.keyType(of: attribute), !needsClient(filter) else { return nil }
        let name = context.name(attribute)
        switch filter.op {
        case "=", "<", "<=", ">", ">=":
            guard let value = typed(filter.value, as: type) else { return nil }
            return "\(name) \(filter.op) \(context.value(value, hint: attribute))"
        case "BETWEEN":
            guard let bounds = Self.bounds(value: filter.value, secondValue: filter.secondValue),
                  let lower = typed(bounds.lower, as: type), let upper = typed(bounds.upper, as: type),
                  !Self.isReversed(lower, upper)
            else { return nil }
            return "\(name) BETWEEN \(context.value(lower, hint: attribute)) AND \(context.value(upper, hint: attribute))"
        case "STARTS WITH":
            guard type == .string || type == .binary, let prefix = typed(filter.value, as: type) else { return nil }
            return "begins_with(\(name), \(context.value(prefix, hint: attribute)))"
        default:
            return nil
        }
    }

    /// Whether the filter can be evaluated by DynamoDB at all.
    func needsClient(_ filter: DynamoDBBrowseFilter) -> Bool {
        if filter.attribute == Self.anyAttributeColumn { return true }
        if filter.op == "ENDS WITH" || filter.op == "REGEX" { return true }
        guard !filter.caseSensitive else { return false }
        return ["=", "!=", "<>", "CONTAINS", "NOT CONTAINS", "STARTS WITH", "IN", "NOT IN"].contains(filter.op)
            && filter.value.lowercased() != filter.value.uppercased()
    }

    func clientPredicate(_ filter: DynamoDBBrowseFilter, path: DynamoDBAttributePath?) -> DynamoDBClientPredicate {
        DynamoDBClientPredicate(
            path: path,
            op: filter.op,
            value: filter.value,
            secondValue: filter.secondValue,
            caseSensitive: filter.caseSensitive
        )
    }

    // MARK: - Typing

    /// Every typed value a filter's text could mean. A key attribute has one type; anything else
    /// may hold a String in one item and a Number in the next, so text that is a valid number is
    /// compared as both rather than guessed.
    func candidates(for path: DynamoDBAttributePath, text: String, kind: String?) -> [DynamoDBAttributeValue] {
        if path.isTopLevel, let keyType = schema.keyType(of: path.root) {
            return typed(text, as: keyType).map { [$0] } ?? []
        }
        var values: [DynamoDBAttributeValue] = [.string(text)]
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if DynamoDBNumber.isValid(trimmed), !trimmed.isEmpty {
            values.append(.number(trimmed))
        }
        switch trimmed.lowercased() {
        case "true": values.append(.bool(true))
        case "false": values.append(.bool(false))
        default: break
        }
        if kind == "integer" || kind == "decimal" {
            values.sort { $0.type == .number && $1.type != .number }
        }
        return values
    }

    private func containsCandidates(_ text: String, path: DynamoDBAttributePath) -> [DynamoDBAttributeValue] {
        var values: [DynamoDBAttributeValue] = [.string(text)]
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if DynamoDBNumber.isValid(trimmed), !trimmed.isEmpty, !(path.isTopLevel && schema.keyType(of: path.root) != nil) {
            values.append(.number(trimmed))
        }
        return values
    }

    func typed(_ text: String, as type: DynamoDBAttributeType) -> DynamoDBAttributeValue? {
        switch type {
        case .number:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return DynamoDBNumber.isValid(trimmed) && !trimmed.isEmpty ? .number(trimmed) : nil
        case .binary:
            return Data(base64Encoded: text).map(DynamoDBAttributeValue.binary)
        default:
            return .string(text)
        }
    }

    static func bounds(value: String, secondValue: String?) -> (lower: String, upper: String)? {
        if let secondValue {
            let upper = secondValue.trimmingCharacters(in: .whitespaces)
            let suffix = ",\(secondValue)"
            let lowerSource = value.hasSuffix(suffix) ? String(value.dropLast(suffix.count)) : value
            let lower = lowerSource.trimmingCharacters(in: .whitespaces)
            guard !lower.isEmpty, !upper.isEmpty else { return nil }
            return (lower, upper)
        }
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    static func isReversed(_ lower: DynamoDBAttributeValue, _ upper: DynamoDBAttributeValue) -> Bool {
        switch (lower, upper) {
        case (.number(let low), .number(let high)):
            return DynamoDBNumber.compare(low, high) == .orderedDescending
        case (.string(let low), .string(let high)):
            return Array(low.utf8).lexicographicallyPrecedes(Array(high.utf8)) == false && low != high
        case (.binary(let low), .binary(let high)):
            return Array(low).lexicographicallyPrecedes(Array(high)) == false && low != high
        default:
            return false
        }
    }

    static func any(_ terms: [String]) -> String {
        terms.count == 1 ? terms[0] : "(" + terms.joined(separator: " OR ") + ")"
    }

    static func all(_ terms: [String]) -> String {
        terms.count == 1 ? terms[0] : "(" + terms.joined(separator: " AND ") + ")"
    }
}
