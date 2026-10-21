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

enum SQLFormatterRulesFile {
    static let fileName = ".sql-formatter.json"
    static let exportFileName = "sql-formatter.json"
    static let maxSize = 64 * 1_024

    static func encode(_ options: SQLFormatterOptions) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(options)
    }

    static func decode(_ data: Data) throws -> SQLFormatterOptions {
        guard data.count <= maxSize else { throw SQLFormatterRulesError.tooLarge }
        do {
            return try JSONDecoder().decode(SQLFormatterOptions.self, from: data)
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
