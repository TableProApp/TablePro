//
//  UserTypeDropping.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

@MainActor
enum UserTypeDropping {
    /// `isConfirmationPreCleared` is for a caller that already asked with its own destructive
    /// alert, so the gate does not ask a second time; Touch ID and the read-only refusal still apply.
    static func drop(
        _ type: UserDefinedTypeInfo,
        cascade: Bool = false,
        in scope: DatabaseScope,
        connection: DatabaseConnection,
        isConfirmationPreCleared: Bool = false,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        let generated = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            driver.generateDropTypeSQL(type: type, cascade: cascade)
        }
        guard let sql = generated else { throw DatabaseObjectCommandError.unsupported }
        try await DatabaseObjectCommandRunner.run(
            sql,
            in: scope,
            connection: connection,
            kind: .destructiveQuery,
            operationDescription: String(localized: "Drop Type"),
            isConfirmationPreCleared: isConfirmationPreCleared,
            gate: gate
        )
        CatalogChangeService.shared.record(
            .changed(CatalogChange(connectionId: connection.id, database: scope.database, kinds: cascade ? .objects : .types))
        )
    }
}
