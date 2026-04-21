//
//  MainContentCoordinator+QueryAnalysis.swift
//  TablePro
//
//  Write-query and dangerous-query detection for MainContentCoordinator.
//

import Foundation

extension MainContentCoordinator {
    // MARK: - DDL Query Detection

    private static let ddlPrefixes: [String] = [
        "CREATE", "DROP", "ALTER", "TRUNCATE", "RENAME",
    ]

    func isDDLQuery(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return Self.ddlPrefixes.contains { trimmed.hasPrefix($0) }
    }

    // MARK: - Write Query Detection

    func isWriteQuery(_ sql: String) -> Bool {
        QueryClassifier.isWriteQuery(sql, databaseType: connection.type)
    }

    // MARK: - Dangerous Query Detection

    func isDangerousQuery(_ sql: String) -> Bool {
        QueryClassifier.isDangerousQuery(sql, databaseType: connection.type)
    }
}
