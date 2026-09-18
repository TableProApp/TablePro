import Foundation

public enum WriteTransactionPolicy {
    public static func opensTransaction(
        supportsTransactions: Bool,
        state: DriverTransactionState,
        statementCount: Int
    ) -> Bool {
        guard supportsTransactions else { return false }
        switch state {
        case .idle, .implicitTransaction:
            return true
        case .explicitTransaction:
            return false
        case .unknown:
            return statementCount > 1
        }
    }
}
