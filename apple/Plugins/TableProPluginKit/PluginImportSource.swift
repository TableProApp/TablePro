//
//  PluginImportSource.swift
//  TableProPluginKit
//

import Foundation

public protocol PluginImportSource: AnyObject, Sendable {
    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error>

    /// The file's statements and `COPY ... FROM STDIN` blocks, in order. A source that reads no `COPY` rows answers
    /// with its statements.
    func elements() async throws -> AsyncThrowingStream<PluginImportElement, Error>

    func fileURL() -> URL
    func fileSizeBytes() -> Int64
    func cleanup()
}

public extension PluginImportSource {
    func cleanup() {}

    func elements() async throws -> AsyncThrowingStream<PluginImportElement, Error> {
        let statements = StatementElements(try await statements())
        return AsyncThrowingStream(unfolding: {
            try await statements.next()
        })
    }
}

// The stream asks for one element at a time, so its iterator is never used from two places at once.
private final class StatementElements: @unchecked Sendable {
    private var statements: AsyncThrowingStream<(statement: String, lineNumber: Int), Error>.AsyncIterator

    init(_ statements: AsyncThrowingStream<(statement: String, lineNumber: Int), Error>) {
        self.statements = statements.makeAsyncIterator()
    }

    func next() async throws -> PluginImportElement? {
        guard let (statement, lineNumber) = try await statements.next() else { return nil }
        return .statement(statement, lineNumber: lineNumber)
    }
}
