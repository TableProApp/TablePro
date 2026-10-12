import Foundation
import TableProPluginKit

public extension DatabaseDriver {
    @discardableResult
    func executeWrite(_ statements: [String]) async throws -> Int {
        guard !statements.isEmpty else { return 0 }

        let opensTransaction = await WriteTransactionPolicy.opensTransaction(
            supportsTransactions: supportsTransactions,
            state: sessionTransactionState(),
            statementCount: statements.count
        )
        guard opensTransaction else { return try await runWriteStatements(statements) }

        try await beginTransaction(mode: .readWrite)
        do {
            let affected = try await runWriteStatements(statements)
            try await commitTransaction()
            return affected
        } catch {
            try? await rollbackTransaction()
            throw error
        }
    }
}

private extension DatabaseDriver {
    func runWriteStatements(_ statements: [String]) async throws -> Int {
        var affected = 0
        for statement in statements {
            let result = try await execute(query: statement)
            affected += max(result.rowsAffected, 0)
        }
        return affected
    }
}
