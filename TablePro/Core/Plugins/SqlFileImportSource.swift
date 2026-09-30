//
//  SqlFileImportSource.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

final class SqlFileImportSource: PluginImportSource, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SqlFileImportSource")

    private let url: URL
    private let encoding: String.Encoding
    private let grammar: SQLLexicalGrammar
    private let family: TransactionEngineFamily
    private let parser = SQLFileParser()

    private let externalDecompressedURL: URL?
    private let _decompressedURL = OSAllocatedUnfairLock<URL?>(initialState: nil)
    private let ownsDecompressedFile: Bool

    init(
        url: URL,
        encoding: String.Encoding,
        grammar: SQLLexicalGrammar = .ansi,
        family: TransactionEngineFamily = .other,
        decompressedURL: URL? = nil,
        ownsDecompressedFile: Bool? = nil
    ) {
        self.url = url
        self.encoding = encoding
        self.grammar = grammar
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

    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        let fileURL = try await resolveURL()
        let parsed = parser.parseFile(url: fileURL, encoding: encoding, grammar: grammar)
        guard !sendsFileBytesUnchanged else { return parsed }
        return Self.sentAsUTF8(parsed, decodedFrom: encoding, family: family, grammar: grammar)
    }

    private var sendsFileBytesUnchanged: Bool {
        encoding == .utf8 || encoding == .ascii
    }

    private static func sentAsUTF8(
        _ statements: AsyncThrowingStream<(statement: String, lineNumber: Int), Error>,
        decodedFrom encoding: String.Encoding,
        family: TransactionEngineFamily,
        grammar: SQLLexicalGrammar
    ) -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        let rewriting = TranscodedDumpStatements(statements, decodedFrom: encoding, family: family, grammar: grammar)
        return AsyncThrowingStream(unfolding: {
            try await rewriting.next()
        })
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

        let result = try await FileDecompressor.decompressIfNeeded(url) { $0.path() }

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
    private static let logger = Logger(subsystem: "com.TablePro", category: "SqlFileImportSource")

    private var statements: AsyncThrowingStream<(statement: String, lineNumber: Int), Error>.AsyncIterator
    private let encoding: String.Encoding
    private let family: TransactionEngineFamily
    private let grammar: SQLLexicalGrammar
    private var backslashEscapesAreOn = true

    init(
        _ statements: AsyncThrowingStream<(statement: String, lineNumber: Int), Error>,
        decodedFrom encoding: String.Encoding,
        family: TransactionEngineFamily,
        grammar: SQLLexicalGrammar
    ) {
        self.statements = statements.makeAsyncIterator()
        self.encoding = encoding
        self.family = family
        self.grammar = grammar
    }

    func next() async throws -> (statement: String, lineNumber: Int)? {
        guard let (statement, lineNumber) = try await statements.next() else { return nil }
        let literals = try rewrittenLiterals(of: statement, at: lineNumber) ?? statement
        guard let rewritten = SQLClientEncodingRewriter.rewritten(literals, family: family, grammar: grammar) else {
            return (literals, lineNumber)
        }
        Self.logger.info("Kept the session's client encoding at line \(lineNumber, privacy: .public), since the import sends UTF-8")
        return (rewritten, lineNumber)
    }

    private func rewrittenLiterals(of statement: String, at lineNumber: Int) throws -> String? {
        guard family == .mysql else { return nil }
        defer {
            backslashEscapesAreOn = SQLTranscodedLiteralRewriter.backslashEscapesAreOn(
                after: statement,
                currently: backslashEscapesAreOn,
                grammar: grammar
            )
        }
        do {
            return try SQLTranscodedLiteralRewriter.rewritten(
                statement,
                decodedFrom: encoding,
                backslashEscapesAreOn: backslashEscapesAreOn,
                grammar: grammar
            )
        } catch SQLTranscodedLiteralError.unrecoverableBinaryLiteral {
            throw SqlFileImportError.unrecoverableBinaryLiteral(line: lineNumber, encoding: String.localizedName(of: encoding))
        }
    }
}
