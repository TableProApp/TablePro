import Foundation
import os
import TableProSQLGrammar

public enum SqlFileImportError: LocalizedError, Equatable {
    case unrecoverableBinaryLiteral(line: Int, encoding: String)

    public var errorDescription: String? {
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

// The import sends UTF-8, so a dump decoded from any other encoding has its literals and its client encoding
// statements rewritten to read back the same.
public struct SQLDumpStatementRewriter: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLDumpStatementRewriter")

    public let encoding: String.Encoding
    public let family: SQLDumpFamily
    public let grammar: @Sendable () -> SQLLexicalGrammar

    public init(encoding: String.Encoding, family: SQLDumpFamily, grammar: @escaping @Sendable () -> SQLLexicalGrammar) {
        self.encoding = encoding
        self.family = family
        self.grammar = grammar
    }

    // UTF-8 and ASCII reach the server as the file holds them.
    public static func rewrites(fileDecodedFrom encoding: String.Encoding) -> Bool {
        encoding != .utf8 && encoding != .ascii
    }

    public func rewritten(_ statement: String, at lineNumber: Int) throws -> String {
        let grammar = self.grammar()
        let literals = try rewrittenLiterals(of: statement, at: lineNumber, grammar: grammar) ?? statement
        guard let rewritten = SQLClientEncodingRewriter.rewritten(literals, family: family, grammar: grammar) else {
            return literals
        }
        Self.logger.info("Kept the session's client encoding at line \(lineNumber, privacy: .public), since the import sends UTF-8")
        return rewritten
    }

    public func rewriting(
        _ statements: AsyncThrowingStream<(statement: String, lineNumber: Int), Error>
    ) -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        let rewriting = RewrittenStatements(statements, rewriter: self)
        return AsyncThrowingStream(unfolding: {
            try await rewriting.next()
        })
    }

    public func rewriting(_ elements: AsyncThrowingStream<SQLFileElement, Error>) -> AsyncThrowingStream<SQLFileElement, Error> {
        let rewriting = RewrittenElements(elements, rewriter: self)
        return AsyncThrowingStream(unfolding: {
            try await rewriting.next()
        })
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

private final class RewrittenStatements: @unchecked Sendable {
    private var statements: AsyncThrowingStream<(statement: String, lineNumber: Int), Error>.AsyncIterator
    private let rewriter: SQLDumpStatementRewriter

    init(_ statements: AsyncThrowingStream<(statement: String, lineNumber: Int), Error>, rewriter: SQLDumpStatementRewriter) {
        self.statements = statements.makeAsyncIterator()
        self.rewriter = rewriter
    }

    func next() async throws -> (statement: String, lineNumber: Int)? {
        guard let (statement, lineNumber) = try await statements.next() else { return nil }
        return (try rewriter.rewritten(statement, at: lineNumber), lineNumber)
    }
}

// COPY rows pass unchanged: the parser hands them out as UTF-8 already.
private final class RewrittenElements: @unchecked Sendable {
    private var elements: AsyncThrowingStream<SQLFileElement, Error>.AsyncIterator
    private let rewriter: SQLDumpStatementRewriter

    init(_ elements: AsyncThrowingStream<SQLFileElement, Error>, rewriter: SQLDumpStatementRewriter) {
        self.elements = elements.makeAsyncIterator()
        self.rewriter = rewriter
    }

    func next() async throws -> SQLFileElement? {
        guard let element = try await elements.next() else { return nil }
        guard case let .statement(statement, line) = element else { return element }
        return .statement(try rewriter.rewritten(statement, at: line), line: line)
    }
}
