import Foundation

public enum MemcachedColumn: String, CaseIterable, Sendable {
    case key = "Key"
    case value = "Value"
    case ttl = "TTL"
    case flags = "Flags"

    public var typeName: String {
        switch self {
        case .key, .value: return "String"
        case .ttl, .flags: return "Int64"
        }
    }
}

public enum MemcachedKeyComparison: String, Codable, CaseIterable, Sendable {
    case equal = "="
    case notEqual = "!="
    case contains = "CONTAINS"
    case notContains = "NOT CONTAINS"
    case startsWith = "STARTS WITH"
    case endsWith = "ENDS WITH"
    case inList = "IN"
    case notInList = "NOT IN"
    case regex = "REGEX"
}

public enum MemcachedFilterRefusal: Error, Equatable, Sendable {
    case notKeyColumn(String)
    case unsupportedOperator(String)
    case emptyList(String)
    case invalidPattern(String)
}

/// A page of the key grid. The grid hands the driver this spec as a tagged statement, so a page, its sort and its
/// filter reach the driver the way every other statement does.
public struct MemcachedBrowseSpec: Codable, Equatable, Sendable {
    public struct KeyCondition: Codable, Equatable, Sendable {
        public let comparison: MemcachedKeyComparison
        public let value: String
        public let isCaseSensitive: Bool

        public init(comparison: MemcachedKeyComparison, value: String, isCaseSensitive: Bool) {
            self.comparison = comparison
            self.value = value
            self.isCaseSensitive = isCaseSensitive
        }
    }

    public static let tag = "MEMCACHED_BROWSE:"
    public static let refusalTag = "MEMCACHED_REFUSAL:"

    public let limit: Int
    public let offset: Int
    public let ascending: Bool
    public let conditions: [KeyCondition]
    public let matchesAll: Bool

    public init(limit: Int, offset: Int, ascending: Bool, conditions: [KeyCondition] = [], matchesAll: Bool = true) {
        self.limit = limit
        self.offset = offset
        self.ascending = ascending
        self.conditions = conditions
        self.matchesAll = matchesAll
    }

    public var statement: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return Self.tag + ((try? encoder.encode(self)) ?? Data()).base64EncodedString()
    }

    public static func parse(_ statement: String) -> MemcachedBrowseSpec? {
        guard statement.hasPrefix(tag), let data = Data(base64Encoded: String(statement.dropFirst(tag.count))) else {
            return nil
        }
        guard let spec = try? JSONDecoder().decode(MemcachedBrowseSpec.self, from: data),
              spec.limit >= 0, spec.offset >= 0 else { return nil }
        return spec
    }

    public static func refusalStatement(_ message: String) -> String {
        refusalTag + Data(message.utf8).base64EncodedString()
    }

    public static func refusalMessage(_ statement: String) -> String? {
        guard statement.hasPrefix(refusalTag),
              let data = Data(base64Encoded: String(statement.dropFirst(refusalTag.count))) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    public static func condition(
        column: String, op: String, value: String, isCaseSensitive: Bool
    ) throws(MemcachedFilterRefusal) -> KeyCondition {
        guard column == MemcachedColumn.key.rawValue else { throw .notKeyColumn(column) }
        let name = op.trimmingCharacters(in: .whitespaces).uppercased()
        guard let comparison = MemcachedKeyComparison(rawValue: name) else { throw .unsupportedOperator(op) }
        let condition = KeyCondition(comparison: comparison, value: value, isCaseSensitive: isCaseSensitive)
        _ = try KeyTest(condition)
        return condition
    }

    /// The keys this page shows, out of every key listed: filtered, sorted by key, then cut to the page.
    public func page(of keys: [MemcachedKeyEntry]) throws(MemcachedFilterRefusal) -> [MemcachedKeyEntry] {
        let matching = try filter(keys)
        let sorted = matching.sorted { ascending ? $0.key < $1.key : $0.key > $1.key }
        guard offset < sorted.count else { return [] }
        return Array(sorted[offset ..< offset + min(limit, sorted.count - offset)])
    }

    public func filter(_ keys: [MemcachedKeyEntry]) throws(MemcachedFilterRefusal) -> [MemcachedKeyEntry] {
        guard !conditions.isEmpty else { return keys }
        var tests: [KeyTest] = []
        for condition in conditions { tests.append(try KeyTest(condition)) }
        return keys.filter { entry in
            matchesAll ? tests.allSatisfy { $0.matches(entry.key) } : tests.contains { $0.matches(entry.key) }
        }
    }
}

private struct KeyTest {
    let condition: MemcachedBrowseSpec.KeyCondition
    let items: [String]
    let regex: NSRegularExpression?

    init(_ condition: MemcachedBrowseSpec.KeyCondition) throws(MemcachedFilterRefusal) {
        self.condition = condition
        switch condition.comparison {
        case .inList, .notInList:
            items = condition.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !items.isEmpty else { throw .emptyList(condition.comparison.rawValue) }
            regex = nil
        case .regex:
            items = []
            let options: NSRegularExpression.Options = condition.isCaseSensitive ? [] : [.caseInsensitive]
            guard let compiled = try? NSRegularExpression(pattern: condition.value, options: options) else {
                throw .invalidPattern(condition.value)
            }
            regex = compiled
        default:
            items = []
            regex = nil
        }
    }

    func matches(_ key: String) -> Bool {
        let options: String.CompareOptions = condition.isCaseSensitive ? [.literal] : [.caseInsensitive]
        let value = condition.value
        switch condition.comparison {
        case .equal: return key.compare(value, options: options) == .orderedSame
        case .notEqual: return key.compare(value, options: options) != .orderedSame
        case .contains: return key.range(of: value, options: options) != nil
        case .notContains: return key.range(of: value, options: options) == nil
        case .startsWith: return key.range(of: value, options: options.union(.anchored)) != nil
        case .endsWith: return key.range(of: value, options: options.union([.anchored, .backwards])) != nil
        case .inList: return items.contains { key.compare($0, options: options) == .orderedSame }
        case .notInList: return !items.contains { key.compare($0, options: options) == .orderedSame }
        case .regex:
            let range = NSRange(key.startIndex..., in: key)
            return regex?.firstMatch(in: key, range: range) != nil
        }
    }
}
