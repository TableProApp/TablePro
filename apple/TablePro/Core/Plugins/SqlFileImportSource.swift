//
//  SqlFileImportSource.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLFile
import TableProSQLGrammar

final class SqlFileImportSource: PluginImportSource, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SqlFileImportSource")

    private let url: URL
    private let encoding: String.Encoding
    private let grammar: OSAllocatedUnfairLock<@Sendable () -> SQLLexicalGrammar>
    private let readReporter = OSAllocatedUnfairLock<(@Sendable (Int64, Int64) -> Void)?>(initialState: nil)
    private let family: TransactionEngineFamily
    private let parser = SQLFileParser()

    private let externalDecompressedURL: URL?
    private let _decompressedURL = OSAllocatedUnfairLock<URL?>(initialState: nil)
    private let ownsDecompressedFile: Bool

    init(
        url: URL,
        encoding: String.Encoding,
        grammar: @escaping @Sendable () -> SQLLexicalGrammar = { .ansi },
        family: TransactionEngineFamily = .other,
        decompressedURL: URL? = nil,
        ownsDecompressedFile: Bool? = nil
    ) {
        self.url = url
        self.encoding = encoding
        self.grammar = OSAllocatedUnfairLock(initialState: grammar)
        self.family = family
        self.externalDecompressedURL = decompressedURL
        self.ownsDecompressedFile = ownsDecompressedFile ?? (decompressedURL == nil)
    }

    func fileURL() -> URL {
        url
    }

    func fileSizeBytes() -> Int64 {
        let targetURL = effectiveURL
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: targetURL.path(percentEncoded: false))
            return attrs[.size] as? Int64 ?? 0
        } catch {
            Self.logger.warning("Failed to get file size for \(targetURL.path(percentEncoded: false)): \(error.localizedDescription)")
            return 0
        }
    }

    // The source is built before the import leases its session, so the session's grammar arrives here.
    func readsGrammar(from provider: @escaping @Sendable () -> SQLLexicalGrammar) {
        grammar.withLock { $0 = provider }
    }

    // Bytes read from the file the parser opens, which for a `.gz` is the decompressed copy.
    func reportsReading(to handler: @escaping @Sendable (_ bytesRead: Int64, _ fileSize: Int64) -> Void) {
        readReporter.withLock { $0 = handler }
    }

    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        let fileURL = try await resolveURL()
        let grammar = self.grammar.withLock { $0 }
        let onRead = readReporter.withLock { $0 }
        let parsed = parser.parseFile(url: fileURL, encoding: encoding, grammar: grammar, onRead: onRead)
        guard SQLDumpStatementRewriter.rewrites(fileDecodedFrom: encoding) else { return parsed }
        return rewriter(grammar: grammar).rewriting(parsed)
    }

    func elements() async throws -> AsyncThrowingStream<PluginImportElement, Error> {
        let fileURL = try await resolveURL()
        let grammar = self.grammar.withLock { $0 }
        let onRead = readReporter.withLock { $0 }
        var parsed = parser.parseElements(url: fileURL, encoding: encoding, grammar: grammar, onRead: onRead)
        if SQLDumpStatementRewriter.rewrites(fileDecodedFrom: encoding) {
            parsed = rewriter(grammar: grammar).rewriting(parsed)
        }
        let elements = PluginElements(parsed)
        return AsyncThrowingStream(unfolding: {
            try await elements.next()
        })
    }

    private func rewriter(grammar: @escaping @Sendable () -> SQLLexicalGrammar) -> SQLDumpStatementRewriter {
        SQLDumpStatementRewriter(encoding: encoding, family: family.dumpFamily, grammar: grammar)
    }

    // A file this source decompressed is always its own to remove: a retry arrives with the flag off, and gating on it
    // leaked the whole expanded dump.
    func cleanup() {
        let tempURL = _decompressedURL.withLock {
            let url = $0
            $0 = nil
            return url
        }
        let external = ownsDecompressedFile ? externalDecompressedURL : nil

        for fileURL in [tempURL, external].compactMap({ $0 }) {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                Self.logger.warning("Failed to clean up temp file: \(error.localizedDescription)")
            }
        }
    }

    deinit {
        let tempURL = _decompressedURL.withLock { $0 }
        let external = ownsDecompressedFile ? externalDecompressedURL : nil
        for fileURL in [tempURL, external].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Private

    private var effectiveURL: URL {
        if let external = externalDecompressedURL {
            return external
        }
        if let decompressed = _decompressedURL.withLock({ $0 }) {
            return decompressed
        }
        return url
    }

    private func resolveURL() async throws -> URL {
        if let external = externalDecompressedURL {
            return external
        }

        if let existing = _decompressedURL.withLock({ $0 }) {
            return existing
        }

        let result = try await FileDecompressor.decompressIfNeeded(url)

        if result != url {
            _decompressedURL.withLock { $0 = result }
        }

        return result
    }
}

extension TransactionEngineFamily {
    var dumpFamily: SQLDumpFamily {
        switch self {
        case .mysql:
            return .mysql
        case .postgres, .redshift, .cockroach:
            return .postgres
        case .sqlite, .duckdb, .sqlServer, .oracle, .redis, .teradata, .other:
            return .other
        }
    }
}

private final class PluginElements: @unchecked Sendable {
    private var elements: AsyncThrowingStream<SQLFileElement, Error>.AsyncIterator

    init(_ elements: AsyncThrowingStream<SQLFileElement, Error>) {
        self.elements = elements.makeAsyncIterator()
    }

    func next() async throws -> PluginImportElement? {
        switch try await elements.next() {
        case let .statement(statement, line)?:
            return .statement(statement, lineNumber: line)
        case let .copyFromStandardInput(statement, line, readRows)?:
            return .copyFromStandardInput(statement: statement, lineNumber: line, rows: PluginCopyData(read: readRows))
        case nil:
            return nil
        }
    }
}
