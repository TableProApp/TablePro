import Foundation

public enum SavedQueryScopeRule {
    public static func folder(_ folderScope: UUID?, canHold recordScope: UUID?) -> Bool {
        folderScope == nil || folderScope == recordScope
    }
}

public enum SavedQuerySize {
    public static let maximumSyncableByteCount = 900_000

    public static func byteCount(name: String, sql: String, keyword: String?) -> Int {
        name.utf8.count + sql.utf8.count + (keyword?.utf8.count ?? 0)
    }
}

public enum SavedQueryKeyword {
    public static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    public static let reservedSQLKeywords: Set<String> = [
        "select", "from", "where", "insert", "update", "delete",
        "create", "drop", "alter", "join", "on", "and", "or",
        "not", "in", "like", "between", "order", "group", "having",
        "limit", "set", "values", "into", "as", "is", "null",
        "true", "false", "case", "when", "then", "else", "end"
    ]

    public static func isValid(_ keyword: String) -> Bool {
        keyword.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    public static func shadowsSQLKeyword(_ keyword: String) -> Bool {
        reservedSQLKeywords.contains(keyword.lowercased())
    }
}

public enum SavedQueryName {
    public static func derived(from sql: String) -> String {
        let text = sql as NSString
        let length = text.length
        var lineStart = 0
        while lineStart < length {
            var lineEnd = lineStart
            while lineEnd < length {
                let character = text.character(at: lineEnd)
                if character == 0x0A || character == 0x0D { break }
                lineEnd += 1
            }
            if lineEnd > lineStart {
                let line = text.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
                    .trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("--") {
                    let comment = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !comment.isEmpty {
                        return prefix(comment)
                    }
                } else if !line.isEmpty {
                    return prefix(line)
                }
            }
            lineStart = lineEnd + 1
        }
        return String(localized: "Untitled")
    }

    private static func prefix(_ line: String) -> String {
        let text = line as NSString
        return text.substring(to: min(50, text.length))
    }
}

public enum SavedQueryKeywordDrop: Equatable, Sendable {
    case inUse(String)
    case invalid(String)
}

public enum SavedQueryVerdict: Equatable, Sendable {
    case insert(keyword: String?, dropped: SavedQueryKeywordDrop?, nameExists: Bool)
    case alreadySaved
    case tooLarge(byteCount: Int)
}

public struct SavedQueryLedger: Sendable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let sql: String
        public let keyword: String?
        public let connectionId: UUID?

        public init(name: String, sql: String, keyword: String?, connectionId: UUID?) {
            self.name = name
            self.sql = sql
            self.keyword = keyword
            self.connectionId = connectionId
        }
    }

    private struct ContentKey: Hashable {
        let scope: UUID?
        let name: String
        let sql: String
    }

    private struct NameKey: Hashable {
        let scope: UUID?
        let name: String
    }

    private var contents: Set<ContentKey> = []
    private var names: Set<NameKey> = []
    private var keywordScopes: [String: Set<UUID?>] = [:]

    public init(_ entries: [Entry]) {
        for entry in entries {
            record(entry)
        }
    }

    public func verdict(name: String, sql: String, keyword: String?, scope: UUID?) -> SavedQueryVerdict {
        let keyword = SavedQueryKeyword.normalized(keyword)
        let byteCount = SavedQuerySize.byteCount(name: name, sql: sql, keyword: keyword)
        guard byteCount <= SavedQuerySize.maximumSyncableByteCount else {
            return .tooLarge(byteCount: byteCount)
        }

        let nameKey = Self.normalizedName(name)
        if contents.contains(ContentKey(scope: scope, name: nameKey, sql: Self.normalizedSQL(sql))) {
            return .alreadySaved
        }
        let nameExists = names.contains(NameKey(scope: scope, name: nameKey))

        guard let keyword else {
            return .insert(keyword: nil, dropped: nil, nameExists: nameExists)
        }
        // A file's keyword that shadows SQL would outrank the SQL keyword in completion.
        guard SavedQueryKeyword.isValid(keyword), !SavedQueryKeyword.shadowsSQLKeyword(keyword) else {
            return .insert(keyword: nil, dropped: .invalid(keyword), nameExists: nameExists)
        }
        guard isKeywordAvailable(keyword, scope: scope) else {
            return .insert(keyword: nil, dropped: .inUse(keyword), nameExists: nameExists)
        }
        return .insert(keyword: keyword, dropped: nil, nameExists: nameExists)
    }

    public mutating func record(_ entry: Entry) {
        let nameKey = Self.normalizedName(entry.name)
        contents.insert(ContentKey(scope: entry.connectionId, name: nameKey, sql: Self.normalizedSQL(entry.sql)))
        names.insert(NameKey(scope: entry.connectionId, name: nameKey))
        if let keyword = entry.keyword, !keyword.isEmpty {
            keywordScopes[keyword, default: []].insert(entry.connectionId)
        }
    }

    /// Mirrors `SQLFavoriteStorage.isKeywordAvailable`: a global keyword expands in every connection.
    private func isKeywordAvailable(_ keyword: String, scope: UUID?) -> Bool {
        guard let holders = keywordScopes[keyword], !holders.isEmpty else { return true }
        guard let scope else { return false }
        return !holders.contains(nil) && !holders.contains(scope)
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedSQL(_ sql: String) -> String {
        sql.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
