//
//  SqlFileImportSource.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar
import TableProUtilities

final class SqlFileImportSource: PluginImportSource, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SqlFileImportSource")

    private let url: URL
    private let encoding: String.Encoding
    private let grammar: OSAllocatedUnfairLock<@Sendable () -> SQLLexicalGrammar>
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

    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        let fileURL = try await resolveURL()
        let grammar = self.grammar.withLock { $0 }
        let parsed = parser.parseFile(url: fileURL, encoding: encoding, grammar: grammar)
        guard !sendsFileBytesUnchanged else { return parsed }
        let rewriting = TranscodedDumpStatements(parsed, rewriter: rewriter(grammar: grammar))
        return AsyncThrowingStream(unfolding: {
            try await rewriting.next()
        })
    }

    func elements() async throws -> AsyncThrowingStream<PluginImportElement, Error> {
        let fileURL = try await resolveURL()
        let grammar = self.grammar.withLock { $0 }
        let parsed = parser.parseElements(url: fileURL, encoding: encoding, grammar: grammar)
        guard !sendsFileBytesUnchanged else { return parsed }
        let rewriting = TranscodedDumpElements(parsed, rewriter: rewriter(grammar: grammar))
        return AsyncThrowingStream(unfolding: {
            try await rewriting.next()
        })
    }

    private var sendsFileBytesUnchanged: Bool {
        encoding == .utf8 || encoding == .ascii
    }

    private func rewriter(grammar: @escaping @Sendable () -> SQLLexicalGrammar) -> TranscodedStatementRewriter {
        TranscodedStatementRewriter(encoding: encoding, family: family, grammar: grammar)
    }

    /// `ownsDecompressedFile` answers only whether the caller handed over a file to delete. A file
    /// this source decompressed itself is always its own to remove, and gating that on the same
    /// flag leaked the whole expanded dump every time an import of a `.gz` was retried, because a
    /// retry arrives with no caller-supplied file and therefore with the flag off.
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

internal enum SqlFileImportError: LocalizedError, Equatable {
    case unrecoverableBinaryLiteral(line: Int, encoding: String)

    var errorDescription: String? {
        switch self {
        case .unrecoverableBinaryLiteral(let line, let encoding):
            return String(
                format: String(localized: "Line %@ holds binary data that cannot be read back exactly from a %@ file. Export the dump with --hex-blob, then import it again."),
                line.formatted(),
                encoding
            )
        }
    }
}

private final class TranscodedDumpStatements: @unchecked Sendable {
    private var statements: AsyncThrowingStream<(statement: String, lineNumber: Int), Error>.AsyncIterator
    private let rewriter: TranscodedStatementRewriter

    init(_ statements: AsyncThrowingStream<(statement: String, lineNumber: Int), Error>, rewriter: TranscodedStatementRewriter) {
        self.statements = statements.makeAsyncIterator()
        self.rewriter = rewriter
    }

    func next() async throws -> (statement: String, lineNumber: Int)? {
        guard let (statement, lineNumber) = try await statements.next() else { return nil }
        return (try rewriter.rewritten(statement, at: lineNumber), lineNumber)
    }
}

// COPY rows pass unchanged: the parser hands them out as UTF-8 already.
private final class TranscodedDumpElements: @unchecked Sendable {
    private var elements: AsyncThrowingStream<PluginImportElement, Error>.AsyncIterator
    private let rewriter: TranscodedStatementRewriter

    init(_ elements: AsyncThrowingStream<PluginImportElement, Error>, rewriter: TranscodedStatementRewriter) {
        self.elements = elements.makeAsyncIterator()
        self.rewriter = rewriter
    }

    func next() async throws -> PluginImportElement? {
        guard let element = try await elements.next() else { return nil }
        guard case let .statement(statement, lineNumber) = element else { return element }
        return .statement(try rewriter.rewritten(statement, at: lineNumber), lineNumber: lineNumber)
    }
}

private struct TranscodedStatementRewriter: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SqlFileImportSource")

    let encoding: String.Encoding
    let family: TransactionEngineFamily
    let grammar: @Sendable () -> SQLLexicalGrammar

    func rewritten(_ statement: String, at lineNumber: Int) throws -> String {
        let grammar = self.grammar()
        let literals = try rewrittenLiterals(of: statement, at: lineNumber, grammar: grammar) ?? statement
        guard let rewritten = SQLClientEncodingRewriter.rewritten(literals, family: family, grammar: grammar) else {
            return literals
        }
        Self.logger.info("Kept the session's client encoding at line \(lineNumber, privacy: .public), since the import sends UTF-8")
        return rewritten
    }

    private func rewrittenLiterals(of statement: String, at lineNumber: Int, grammar: SQLLexicalGrammar) throws -> String? {
        guard family == .mysql else { return nil }
        do {
            return try SQLTranscodedLiteralRewriter.rewritten(
                statement,
                decodedFrom: encoding,
                backslashEscapesAreOn: grammar.contains(.backslashEscapesInSingleQuotes),
                grammar: grammar
            )
        } catch SQLTranscodedLiteralError.unrecoverableBinaryLiteral {
            throw SqlFileImportError.unrecoverableBinaryLiteral(line: lineNumber, encoding: String.localizedName(of: encoding))
        }
    }
}
