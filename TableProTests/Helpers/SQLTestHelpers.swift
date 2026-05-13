//
//  SQLTestHelpers.swift
//  TableProTests
//
//  SQL assertion utilities for test suite
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

// MARK: - SQL Normalization

func normalizeSQL(_ sql: String) -> String {
    let normalized = sql
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    return normalized
}

// MARK: - SQL Assertions

func expectSQLContains(
    _ sql: String,
    _ substring: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let normalizedSQL = normalizeSQL(sql).lowercased()
    let normalizedSubstring = normalizeSQL(substring).lowercased()

    #expect(
        normalizedSQL.contains(normalizedSubstring),
        "Expected SQL to contain '\(substring)'\nActual SQL: \(sql)",
        sourceLocation: sourceLocation
    )
}

func expectSQLEquals(
    _ actual: String,
    _ expected: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let normalizedActual = normalizeSQL(actual)
    let normalizedExpected = normalizeSQL(expected)

    #expect(
        normalizedActual == normalizedExpected,
        "SQL mismatch\nExpected: \(normalizedExpected)\nActual: \(normalizedActual)",
        sourceLocation: sourceLocation
    )
}
