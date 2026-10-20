import Foundation

public enum WriteTransactionPolicy {
    public static func opensTransaction(
        supportsTransactions: Bool,
        state: DriverTransactionState,
        statementCount: Int
    ) -> Bool {
        guard supportsTransactions else { return false }
        switch state {
        case .idle:
            return true
        // MySQL's START TRANSACTION commits the work an autocommit-off session holds, so the write joins it.
        case .explicitTransaction, .implicitTransaction, .abortedTransaction:
            return false
        case .unknown:
            return statementCount > 1
        }
    }
}
