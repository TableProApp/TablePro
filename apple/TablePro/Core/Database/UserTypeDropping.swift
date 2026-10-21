//
//  UserTypeDropping.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

@MainActor
enum UserTypeDropping {
    // The gate shows the statement and confirms it as destructive, so no prompt of its own is needed.
    static func drop(
        _ type: UserDefinedTypeInfo,
        in scope: DatabaseScope,
        connection: DatabaseConnection,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        let generated = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            driver.generateDropTypeSQL(type: type)
        }
        guard let sql = generated else { throw DatabaseObjectCommandError.unsupported }
        try await DatabaseObjectCommandRunner.run(
            sql,
            in: scope,
            connection: connection,
            kind: .destructiveQuery,
            operationDescription: String(localized: "Drop Type"),
            gate: gate
        )
        CatalogChangeService.shared.record(
            .changed(CatalogChange(connectionId: connection.id, database: scope.database, kinds: .types))
        )
    }
}
