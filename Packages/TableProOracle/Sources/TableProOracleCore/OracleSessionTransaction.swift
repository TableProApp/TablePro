import Foundation

/// Whether the session has a transaction open, and which connection it lives on.
///
/// Oracle never commits on its own: every write joins a transaction that stays open until something commits it, and
/// oracle-nio sends no commit unless a statement asks for one. TablePro presents every engine the same way, with each
/// statement committed as it runs unless a transaction is open, so a statement run with none open carries the
/// driver's commit flag and the server commits it in the same round trip.
///
/// A transaction opens with ``open()``, which is what the app's own writes call, or with a statement that opens one
/// (``OracleTransactionRole/opensTransaction``). It ends with a `COMMIT` or `ROLLBACK`, whoever sends it.
///
/// The transaction belongs to the connection its first statement ran on. A connection that closes takes the
/// transaction with it, so a statement that finds the transaction's connection replaced fails with
/// ``OracleCoreError/transactionLost`` rather than carrying on in a new session that holds none of the earlier work.
struct OracleSessionTransaction: Equatable, Sendable {
    private(set) var isOpen = false
    private var session: Int?

    mutating func open() {
        isOpen = true
    }

    /// Whether a statement in `role` runs with the commit flag on the connection `session`.
    ///
    /// Inside a transaction nothing commits on its own, and the transaction is bound to `session` if no statement has
    /// bound it yet. A query takes no part: it writes nothing, and it may run on any connection.
    mutating func admit(_ role: OracleTransactionRole, on session: Int) throws -> Bool {
        switch role {
        case .query:
            return false
        case .opensTransaction, .endsTransaction:
            guard isOpen else { return false }
        case .other:
            guard isOpen else { return true }
        }
        try bind(to: session)
        return false
    }

    /// A statement that opens a transaction opens it here only once Oracle has accepted it, and a `COMMIT` or
    /// `ROLLBACK` ends it.
    mutating func statementSucceeded(_ role: OracleTransactionRole, on session: Int) {
        switch role {
        case .opensTransaction:
            isOpen = true
            self.session = session
        case .endsTransaction:
            close()
        case .query, .other:
            break
        }
    }

    /// A `COMMIT` or `ROLLBACK` the server refused ends the transaction only when the server no longer holds one: a
    /// malformed one leaves it open, and a commit a deferred constraint rolled back (ORA-02091) ends it.
    ///
    /// `serverHoldsTransaction` is nil when there was no live connection to ask. The transaction is then left as it
    /// is, and the next write finds out whether its connection survived.
    mutating func statementFailed(_ role: OracleTransactionRole, serverHoldsTransaction: Bool?) {
        guard role == .endsTransaction, serverHoldsTransaction == false else { return }
        close()
    }

    /// What the server answers for the session's own transaction: its id while one is open, NULL otherwise. Named
    /// with its owner, because a bare `DBMS_TRANSACTION` resolves to an object of that name in the current schema first.
    static let serverTransactionQuery = "SELECT SYS.DBMS_TRANSACTION.LOCAL_TRANSACTION_ID FROM SYS.DUAL"

    private mutating func bind(to session: Int) throws {
        if let bound = self.session, bound != session {
            close()
            throw OracleCoreError.transactionLost
        }
        self.session = session
    }

    private mutating func close() {
        isOpen = false
        session = nil
    }
}
