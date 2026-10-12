//
//  MySQLKillLatch.swift
//  MySQLDriverPlugin
//
//  Whether a `KILL QUERY` this connection sent is still waiting on the server for the next
//  statement to collect.
//

import Foundation

/// A `KILL QUERY` that reaches the server after the statement it names has finished is not always
/// dropped. Measured with the app's own libmariadb against an idle session: MySQL 5.5.62, 5.6.51 and
/// MariaDB 5.5.64 hold the flag and hand it to whatever the session runs next, which fails with
/// `ERROR 1317 Query execution was interrupted`; MySQL 5.7.44 and 8.4.11 and MariaDB 10.0.38,
/// 10.1.48 and 10.6.28 drop it.
///
/// Stop is exactly when that happens. The kill goes out on its own connection while the statement it
/// names is already unwinding, so the next statement on the session pays for it: on a batch that is
/// the following statement, and on an export it is the stream.
///
/// Pure, so the ordering is testable without a server. The connection records what it did; the
/// decision to spend a round trip absorbing the flag is this one call.
nonisolated internal struct MySQLKillLatch {
    private var deliveredGeneration: Int?
    private var interruptedGeneration: Int?

    internal init() {}

    /// A kill this connection actually put on the wire, for the statement generation it named.
    internal mutating func recordDelivered(generation: Int) {
        deliveredGeneration = generation
    }

    /// The server answering that generation's statement with its interruption code, which is the
    /// kill being spent rather than held.
    internal mutating func recordInterrupted(generation: Int) {
        interruptedGeneration = generation
    }

    /// Whether the next statement has to absorb a flag the server is still holding, and clears the
    /// latch either way.
    ///
    /// Order-independent on purpose: the kill is delivered from the cancel queue while the statement
    /// it names reads its error on the statement queue, so either can be recorded first.
    internal mutating func takeAbsorption() -> Bool {
        defer {
            deliveredGeneration = nil
            interruptedGeneration = nil
        }
        guard let delivered = deliveredGeneration else { return false }
        return interruptedGeneration != delivered
    }

    /// Only the two engines measured to hold an idle kill pay the absorbing round trip. TiDB drops
    /// the session on `KILL QUERY` instead of flagging it, and Databend and OceanBase are unmeasured,
    /// so neither gets a statement inserted into its session on a guess.
    internal static func absorbsLatchedKill(flavor: MySQLServerFlavor) -> Bool {
        switch flavor {
        case .mysql, .mariadb:
            return true
        case .tidb, .databend, .oceanbase:
            return false
        }
    }
}
