//
//  SQLImportBatch.swift
//  SQLImportPlugin
//

import Foundation
import TableProPluginKit

// Bounded so Stop and Pause still land between exchanges, and a file of large INSERTs is not held whole.
nonisolated struct SQLImportBatch {
    static let statementLimit = 200
    static let byteLimit = 4 << 20

    private var statements: [PluginImportStatement] = []
    private var bytes = 0

    var isEmpty: Bool {
        statements.isEmpty
    }

    var isFull: Bool {
        statements.count >= Self.statementLimit || bytes >= Self.byteLimit
    }

    mutating func append(_ statement: PluginImportStatement) {
        statements.append(statement)
        bytes += statement.text.utf8.count
    }

    mutating func take() -> [PluginImportStatement] {
        defer {
            statements = []
            bytes = 0
        }
        return statements
    }
}
