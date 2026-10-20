import Foundation

public enum DriverTransactionState: Sendable, Equatable {
    case idle
    case explicitTransaction
    case implicitTransaction
    // A statement failed inside the transaction: the server refuses everything until a ROLLBACK, and a COMMIT rolls back.
    case abortedTransaction
    case unknown
}
