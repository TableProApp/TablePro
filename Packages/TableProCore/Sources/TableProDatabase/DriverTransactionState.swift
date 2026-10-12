import Foundation

public enum DriverTransactionState: Sendable, Equatable {
    case idle
    case explicitTransaction
    case implicitTransaction
    case unknown
}
