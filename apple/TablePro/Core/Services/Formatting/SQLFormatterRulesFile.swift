//
//  SQLFormatterRulesFile.swift
//  TablePro
//

import Foundation

enum SQLFormatterRulesError: LocalizedError, Equatable {
    case tooLarge
    case notJSON
    case invalidValue(key: String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge:
            return String(
                format: String(localized: "The file is larger than %@, too large for a rules file."),
                ByteCountFormatter.string(fromByteCount: Int64(SQLFormatterRulesFile.maxSize), countStyle: .file)
            )
        case .notJSON:
            return String(localized: "The file is not a JSON object.")
        case .invalidValue(let key):
            return String(format: String(localized: "The value of “%@” is not valid."), key)
        case .unreadable(let reason):
            return reason
        }
    }
}

struct SQLFormatterFolderRulesError: LocalizedError {
    let fileURL: URL
    let reason: SQLFormatterRulesError

    var errorDescription: String? {
        String(
            format: String(localized: "The formatter rules in “%@” could not be read. %@"),
            fileURL.path,
            reason.localizedDescription
        )
    }
}

// The npm sql-formatter reads the same `.sql-formatter.json`, so a file either tool writes drives both. A rule both
// tools have uses sql-formatter's key and values; a TablePro-only rule uses a key sql-formatter ignores, never one it
// refuses (it throws on `commaPosition`, `aliasAs`, `tabulateAlias`, `multilineLists`, `newlineBeforeOpenParen`,
// `newlineBeforeCloseParen`); a sql-formatter option TablePro does not have, such as `language`, is ignored.
enum SQLFormatterRulesFile {
    static let fileName = ".sql-formatter.json"
    static let exportFileName = "sql-formatter.json"
    static let maxSize = 64 * 1_024

    enum Key: String, CodingKey, CaseIterable {
        case tabWidth
        case useTabs
        case keywordCase
        case functionCase
        case dataTypeCase
        case logicalOperatorNewline
        case commaPlacement
        case lineWidth
        case joinCondition
        case alignAliases
        case clauseItems
    }

    // sql-formatter's own key. TablePro has no tabular layout, so a value sql-formatter documents is read and ignored.
    static let indentStyleKey = "indentStyle"
    static let sqlFormatterIndentStyles: Set<String> = ["standard", "tabularLeft", "tabularRight"]

    static func encode(_ options: SQLFormatterOptions) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(FileRules(options: options))
    }

    static func decode(_ data: Data) throws -> SQLFormatterOptions {
        guard data.count <= maxSize else { throw SQLFormatterRulesError.tooLarge }
        do {
            return try JSONDecoder().decode(FileRules.self, from: data).options
        } catch let error as DecodingError {
            throw rulesError(for: error)
        }
    }

    // A rules file comes with a repository and may link to a device or a pipe, so only a regular file is read.
    static func load(from url: URL) throws -> SQLFormatterOptions {
        do {
            let target = url.resolvingSymlinksInPath()
            let values = try target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw SQLFormatterRulesError.unreadable(String(localized: "The rules file is not a regular file."))
            }
            guard (values.fileSize ?? 0) <= maxSize else { throw SQLFormatterRulesError.tooLarge }
            let handle = try FileHandle(forReadingFrom: target)
            defer { try? handle.close() }
            return try decode(try handle.read(upToCount: maxSize + 1) ?? Data())
        } catch let error as SQLFormatterRulesError {
            throw error
        } catch {
            throw SQLFormatterRulesError.unreadable(error.localizedDescription)
        }
    }

    // Nearest rules file from the SQL file's folder up to its enabled linked folder's root, never above.
    static func url(
        forFileAt fileURL: URL,
        in folders: [LinkedSQLFolder],
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        let file = fileURL.resolvingSymlinksInPath().pathComponents
        let roots = folders
            .filter(\.isEnabled)
            .map { $0.expandedURL.resolvingSymlinksInPath().pathComponents }
            .filter { $0.count < file.count && Array(file.prefix($0.count)) == $0 }
        guard let root = roots.max(by: { $0.count < $1.count }) else { return nil }

        var directory = Array(file.dropLast())
        while directory.count >= root.count {
            let candidate = URL(fileURLWithPath: NSString.path(withComponents: directory + [fileName]))
            if fileExists(candidate) { return candidate }
            directory.removeLast()
        }
        return nil
    }

    private static func rulesError(for error: DecodingError) -> SQLFormatterRulesError {
        let path: [CodingKey]
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            path = context.codingPath
        case .keyNotFound(_, let context):
            path = context.codingPath
        @unknown default:
            path = []
        }
        guard let key = path.first?.stringValue else { return .notJSON }
        return .invalidValue(key: key)
    }
}

// Strict: a value this build cannot read throws and names its key, a key it does not know is ignored.
private struct FileRules: Codable {
    typealias Key = SQLFormatterRulesFile.Key

    let options: SQLFormatterOptions

    init(options: SQLFormatterOptions) {
        self.options = options
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var options = SQLFormatterOptions.default
        if let useTabs = try container.decodeIfPresent(Bool.self, forKey: .useTabs) {
            options.indentStyle = useTabs ? .tabs : .spaces
        }
        options.indentWidth = try Self.decodeInt(container, .tabWidth, in: SQLFormatterOptions.indentWidthRange)
            ?? options.indentWidth
        options.keywordCase = try container.decodeIfPresent(SQLFormatterCase.self, forKey: .keywordCase)
            ?? options.keywordCase
        options.functionCase = try container.decodeIfPresent(SQLFormatterCase.self, forKey: .functionCase)
            ?? options.functionCase
        options.dataTypeCase = try container.decodeIfPresent(SQLFormatterCase.self, forKey: .dataTypeCase)
            ?? options.dataTypeCase
        options.logicalOperatorNewline = try container.decodeIfPresent(
            SQLFormatterLogicalOperatorNewline.self, forKey: .logicalOperatorNewline
        ) ?? options.logicalOperatorNewline
        options.commaPosition = try container.decodeIfPresent(SQLFormatterCommaPosition.self, forKey: .commaPlacement)
            ?? options.commaPosition
        options.lineWidth = try Self.decodeInt(container, .lineWidth, in: SQLFormatterOptions.lineWidthRange)
            ?? options.lineWidth
        options.joinCondition = try container.decodeIfPresent(SQLFormatterJoinCondition.self, forKey: .joinCondition)
            ?? options.joinCondition
        options.alignAliases = try container.decodeIfPresent(Bool.self, forKey: .alignAliases) ?? options.alignAliases
        options.clauseItems = try container.decodeIfPresent(SQLFormatterClauseItems.self, forKey: .clauseItems)
            ?? options.clauseItems

        let shared = try decoder.container(keyedBy: AnyKey.self)
        let indentStyleKey = AnyKey(stringValue: SQLFormatterRulesFile.indentStyleKey)
        if let indentStyle = try shared.decodeIfPresent(String.self, forKey: indentStyleKey),
           !SQLFormatterRulesFile.sqlFormatterIndentStyles.contains(indentStyle) {
            throw DecodingError.dataCorruptedError(
                forKey: indentStyleKey,
                in: shared,
                debugDescription: "indentStyle must be one of sql-formatter's values"
            )
        }
        self.options = options
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(options.indentWidth, forKey: .tabWidth)
        try container.encode(options.indentStyle == .tabs, forKey: .useTabs)
        try container.encode(options.keywordCase, forKey: .keywordCase)
        try container.encode(options.functionCase, forKey: .functionCase)
        try container.encode(options.dataTypeCase, forKey: .dataTypeCase)
        try container.encode(options.logicalOperatorNewline, forKey: .logicalOperatorNewline)
        try container.encode(options.commaPosition, forKey: .commaPlacement)
        try container.encode(options.lineWidth, forKey: .lineWidth)
        try container.encode(options.joinCondition, forKey: .joinCondition)
        try container.encode(options.alignAliases, forKey: .alignAliases)
        try container.encode(options.clauseItems, forKey: .clauseItems)
    }

    private static func decodeInt(
        _ container: KeyedDecodingContainer<Key>,
        _ key: Key,
        in range: ClosedRange<Int>
    ) throws -> Int? {
        guard let value = try container.decodeIfPresent(Int.self, forKey: key) else { return nil }
        guard range.contains(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be between \(range.lowerBound) and \(range.upperBound)"
            )
        }
        return value
    }
}

@MainActor
enum SQLFormatterRuleSource {
    // A rules file in the linked folder wins over Settings, so every Mac formats that folder alike.
    static func options(
        forFileAt fileURL: URL?,
        settings: @autoclosure () -> SQLFormatterOptions = AppSettingsManager.shared.formatterOptions,
        folders: [LinkedSQLFolder] = LinkedSQLFolderStorage.shared.loadFolders()
    ) throws -> SQLFormatterOptions {
        guard let fileURL, let rulesURL = SQLFormatterRulesFile.url(forFileAt: fileURL, in: folders) else {
            return settings()
        }
        do {
            return try SQLFormatterRulesFile.load(from: rulesURL)
        } catch let error as SQLFormatterRulesError {
            throw SQLFormatterFolderRulesError(fileURL: rulesURL, reason: error)
        }
    }
}
