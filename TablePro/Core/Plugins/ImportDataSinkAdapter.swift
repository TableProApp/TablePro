//
//  ImportDataSinkAdapter.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

final class ImportDataSinkAdapter: PluginImportDataSink, @unchecked Sendable {
    let databaseTypeId: String
    private let driver: DatabaseDriver

    private static let logger = Logger(subsystem: "com.TablePro", category: "ImportDataSinkAdapter")

    init(driver: DatabaseDriver, databaseType: DatabaseType) {
        self.driver = driver
        self.databaseTypeId = databaseType.rawValue
    }

    func execute(statement: String) async throws {
        _ = try await driver.execute(query: statement)
    }

    func beginTransaction() async throws {
        try await driver.beginTransaction()
    }

    func commitTransaction() async throws {
        try await driver.commitTransaction()
    }

    func rollbackTransaction() async throws {
        try await driver.rollbackTransaction()
    }

    func disableForeignKeyChecks() async throws {
        guard let statements = driver.foreignKeyDisableStatements() else { return }
        for stmt in statements {
            _ = try await driver.execute(query: stmt)
        }
    }

    func enableForeignKeyChecks() async throws {
        guard let statements = driver.foreignKeyEnableStatements() else { return }
        for stmt in statements {
            _ = try await driver.execute(query: stmt)
        }
    }
}
