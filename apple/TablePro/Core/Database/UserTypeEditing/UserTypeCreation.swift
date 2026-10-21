//
//  UserTypeCreation.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor
enum UserTypeCreation {
    /// The driver's statements for the definition, or nil for a kind it cannot create.
    static func statements(
        for definition: PluginUserDefinedTypeDefinition,
        in scope: DatabaseScope
    ) async throws -> [String]? {
        try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            driver.createUserDefinedTypeStatements(definition)
        }
    }

    static func create(
        _ definition: PluginUserDefinedTypeDefinition,
        in scope: DatabaseScope,
        connection: DatabaseConnection,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        guard let statements = try await statements(for: definition, in: scope), !statements.isEmpty else {
            throw DatabaseObjectCommandError.unsupported
        }
        let plan = UserTypeChangePlan(
            steps: [UserTypeChangePlan.Step(changeId: UUID(), statements: statements)],
            isDestructive: false
        )
        let outcome = try await UserTypeChangeRunner.run(
            plan,
            in: scope,
            connection: connection,
            operationDescription: String(localized: "Create Type"),
            gate: gate
        )
        if case .failed(_, let message, _) = outcome {
            throw DatabaseError.queryFailed(message)
        }
    }
}
