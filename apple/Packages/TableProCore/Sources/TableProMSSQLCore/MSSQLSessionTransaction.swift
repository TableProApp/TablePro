import Foundation

/// What the session has open, from one round trip.
///
/// `@@TRANCOUNT` counts open transactions, explicit and implicit alike. `XACT_STATE()` answers -1 for one that can no
/// longer be committed, which is what a batch-aborting error leaves behind, and telling the user to commit that one
/// silently discards their work.
///
/// `SET IMPLICIT_TRANSACTIONS ON` alone is not a transaction. Measured on Azure SQL Edge: with the option on and
/// nothing run since, `SELECT @@TRANCOUNT, @@OPTIONS & 2` answered `0 2` and asking again still answered 0, so nothing
/// is pending and a caller's own transaction commits only its own statements. The first statement after that makes
/// `@@TRANCOUNT` 1.
public enum MSSQLSessionTransaction {
    public static let probe = "SELECT @@TRANCOUNT, XACT_STATE()"

    public enum State: Sendable, Equatable {
        case idle
        case open
        case uncommittable
    }

    public static func state(tranCount: String?, transactionState: String?) -> State? {
        guard let count = tranCount.flatMap(integer) else { return nil }
        if transactionState.flatMap(integer) == uncommittableXactState { return .uncommittable }
        return count > 0 ? .open : .idle
    }

    private static let uncommittableXactState = -1

    private static func integer(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces))
    }
}
