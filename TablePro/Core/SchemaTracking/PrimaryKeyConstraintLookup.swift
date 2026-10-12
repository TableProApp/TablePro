//
//  PrimaryKeyConstraintLookup.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

enum PrimaryKeyConstraintLookup {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PrimaryKeyConstraintLookup")

    static func constraintName(
        tableName: String,
        changes: [SchemaChange],
        driver: DatabaseDriver
    ) async -> String? {
        guard changes.contains(where: dropsExistingPrimaryKey) else { return nil }
        guard let schema = (driver as? SchemaSwitchable)?.escapedSchema else { return nil }

        let query = """
            SELECT CONSTRAINT_NAME
            FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS
            WHERE TABLE_SCHEMA = '\(schema)'
              AND TABLE_NAME = '\(driver.escapeStringLiteral(tableName))'
              AND CONSTRAINT_TYPE = 'PRIMARY KEY'
            """

        do {
            let result = try await driver.execute(query: query)
            guard let row = result.rows.first, let name = row.first?.asText, !name.isEmpty else { return nil }
            return name
        } catch {
            logger.warning(
                "Primary key constraint name lookup failed: \(error.publicLogShape, privacy: .public)"
            )
            return nil
        }
    }

    private static func dropsExistingPrimaryKey(_ change: SchemaChange) -> Bool {
        guard case .modifyPrimaryKey(let old, _) = change else { return false }
        return !old.isEmpty
    }
}
