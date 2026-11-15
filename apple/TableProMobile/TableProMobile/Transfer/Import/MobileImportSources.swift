import Foundation
import TableProGzip
import TableProModels
import TableProPluginKit
import TableProSQLFile
import TableProSQLGrammar
import TableProTabularIO

// The macOS `SqlFileImportSource` over the shared `TableProSQLFile` parser: a `.gz` is expanded beside the staged copy
// first, the session's grammar is read again before each statement, and a dump not in UTF-8 has its literals rewritten.
nonisolated final class MobileSQLFileImportSource: PluginImportSource, @unchecked Sendable {
    private let url: URL
    private let encoding: String.Encoding
    private let family: SQLDumpFamily
    private let grammar: @Sendable () -> SQLLexicalGrammar
    private let parser = SQLFileParser()
    private let lock = NSLock()
    private var expandedURL: URL?
    private var onRead: (@Sendable (Int64, Int64) -> Void)?

    init(
        url: URL,
        encoding: String.Encoding,
        family: SQLDumpFamily,
        grammar: @escaping @Sendable () -> SQLLexicalGrammar
    ) {
        self.url = url
        self.encoding = encoding
        self.family = family
        self.grammar = grammar
    }

    // Bytes read from the file the parser opens, which for a `.gz` is the expanded copy.
    func reportsReading(to handler: @escaping @Sendable (_ bytesRead: Int64, _ fileSize: Int64) -> Void) {
        lock.withLock { onRead = handler }
    }

    func fileURL() -> URL {
        url
    }

    func fileSizeBytes() -> Int64 {
        let target = lock.withLock { expandedURL } ?? url
        let size = try? FileManager.default.attributesOfItem(atPath: target.path(percentEncoded: false))[.size] as? NSNumber
        return size?.int64Value ?? 0
    }

    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        let readable = try await resolvedURL()
        let parsed = parser.parseFile(url: readable, encoding: encoding, grammar: grammar, onRead: lock.withLock { onRead })
        guard SQLDumpStatementRewriter.rewrites(fileDecodedFrom: encoding) else { return parsed }
        return rewriter.rewriting(parsed)
    }

    func elements() async throws -> AsyncThrowingStream<PluginImportElement, Error> {
        let readable = try await resolvedURL()
        var parsed = parser.parseElements(url: readable, encoding: encoding, grammar: grammar, onRead: lock.withLock { onRead })
        if SQLDumpStatementRewriter.rewrites(fileDecodedFrom: encoding) {
            parsed = rewriter.rewriting(parsed)
        }
        let elements = SQLFileElements(parsed)
        return AsyncThrowingStream(unfolding: { try await elements.next() })
    }

    func cleanup() {
        let expanded = lock.withLock { () -> URL? in
            defer { expandedURL = nil }
            return expandedURL
        }
        if let expanded { try? FileManager.default.removeItem(at: expanded) }
    }

    deinit {
        if let expandedURL { try? FileManager.default.removeItem(at: expandedURL) }
    }

    private var rewriter: SQLDumpStatementRewriter {
        SQLDumpStatementRewriter(encoding: encoding, family: family, grammar: grammar)
    }

    private func resolvedURL() async throws -> URL {
        if let expanded = lock.withLock({ expandedURL }) { return expanded }
        guard SQLImportFile.isCompressed(url) else { return url }
        let expanded = SQLImportFile.expandedURL(for: url)
        try await GzipFile.decompress(source: url, destination: expanded)
        lock.withLock { expandedURL = expanded }
        return expanded
    }
}

// The parser's elements as the plugin reads them, one pull at a time.
nonisolated private final class SQLFileElements: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<SQLFileElement, Error>.AsyncIterator

    init(_ elements: AsyncThrowingStream<SQLFileElement, Error>) {
        iterator = elements.makeAsyncIterator()
    }

    func next() async throws -> PluginImportElement? {
        switch try await iterator.next() {
        case let .statement(statement, line)?:
            return .statement(statement, lineNumber: line)
        case let .copyFromStandardInput(statement, line, readRows)?:
            return .copyFromStandardInput(statement: statement, lineNumber: line, rows: PluginCopyData(read: readRows))
        case nil:
            return nil
        }
    }
}

nonisolated struct SQLImportFilePreview: Sendable, Equatable {
    // What to read the file as: the selection, or what the file says it is when the selection does not decode it.
    let encoding: String.Encoding
    // Set when the preview did not decode as selected and the file named or looked like another encoding.
    let detectedEncoding: String.Encoding?
    let decodes: Bool
    let isCompressed: Bool
}

nonisolated enum SQLImportFile {
    private static let previewBytes = 5 * 1_024 * 1_024

    static var encodingChoices: [TabularTextEncoding] {
        TabularTextEncoding.allCases
    }

    static func isCompressed(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "gz"
    }

    static func expandedURL(for url: URL) -> URL {
        let inner = url.deletingPathExtension().pathExtension.lowercased()
        return url.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + "." + (inner.isEmpty ? "sql" : inner), isDirectory: false)
    }

    // macOS `TransactionEngineFamily.dumpFamily`, keyed by type id.
    static func dumpFamily(for databaseType: DatabaseType) -> SQLDumpFamily {
        switch databaseType.rawValue {
        case "MySQL", "MariaDB", "TiDB", "OceanBase":
            return .mysql
        case "PostgreSQL", "Redshift", "CockroachDB", "Greenplum", "AlloyDB", "Citus", "KingbaseES":
            return .postgres
        default:
            return .other
        }
    }

    static func grammar(for databaseType: DatabaseType, session: SQLSessionLexicalFacts?) -> SQLLexicalGrammar {
        SQLLexicalReadings.resolve(databaseTypeId: databaseType.rawValue, declared: nil, session: session).execution
    }

    // The import dialog's read of a picked dump, as macOS `ImportDialog.loadFile` makes it.
    @concurrent
    static func preview(
        _ file: StagedImportFile,
        databaseType: DatabaseType,
        selected: String.Encoding = .utf8,
        session: SQLSessionLexicalFacts? = nil
    ) async throws -> SQLImportFilePreview {
        let compressed = isCompressed(file.url)
        let head = try await previewData(of: file.url, compressed: compressed)
        if SQLDumpEncodingChoice.previewDecodes(head, as: selected, isWholeFile: head.count < previewBytes) {
            return SQLImportFilePreview(encoding: selected, detectedEncoding: nil, decodes: true, isCompressed: compressed)
        }
        let detected = SQLDumpEncodingChoice.encoding(
            replacing: selected,
            forPreview: head,
            isWholeFile: head.count < previewBytes,
            family: dumpFamily(for: databaseType),
            grammar: grammar(for: databaseType, session: session)
        )
        return SQLImportFilePreview(
            encoding: detected ?? selected, detectedEncoding: detected, decodes: detected != nil, isCompressed: compressed
        )
    }

    @concurrent
    static func countStatements(
        _ file: StagedImportFile,
        encoding: String.Encoding,
        databaseType: DatabaseType,
        session: SQLSessionLexicalFacts? = nil
    ) async throws -> Int {
        var readable = file.url
        var expanded: URL?
        if isCompressed(file.url) {
            let target = expandedURL(for: file.url)
            try await GzipFile.decompress(source: file.url, destination: target)
            readable = target
            expanded = target
        }
        defer { if let expanded { try? FileManager.default.removeItem(at: expanded) } }
        return try await SQLFileParser().countStatements(
            url: readable, encoding: encoding, grammar: grammar(for: databaseType, session: session)
        )
    }

    // The first 5 MiB a parse would read, through the inflater for a `.gz`.
    private static func previewData(of url: URL, compressed: Bool) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard compressed else { return try handle.read(upToCount: previewBytes) ?? Data() }
        // No expansion ratio, as for a picked file: a dump of zero-filled BLOBs packs past 500:1.
        let inflater = try GzipInflater(budget: GzipFile.budget(availableSpace: nil))
        var output = Data()
        while output.count < previewBytes, let block = try handle.read(upToCount: 64 * 1_024), !block.isEmpty {
            try Task.checkCancellation()
            try block.withUnsafeBytes { raw in
                try inflater.inflate(raw) { piece in
                    guard output.count < previewBytes else { return }
                    output.append(contentsOf: piece.prefix(previewBytes - output.count))
                }
            }
        }
        return output
    }
}
