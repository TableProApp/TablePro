//
//  MySQLSocketTimeout.swift
//  MySQLDriverPlugin
//

import Foundation

internal let mysqlSocketTimeoutGraceSeconds = 30

internal func mysqlSocketTimeoutSeconds(forQueryTimeout queryTimeoutSeconds: Int) -> UInt32 {
    guard queryTimeoutSeconds > 0 else { return 0 }
    let ceiling = Int(UInt32.max) - mysqlSocketTimeoutGraceSeconds
    let clamped = min(queryTimeoutSeconds, ceiling)
    return UInt32(clamped + mysqlSocketTimeoutGraceSeconds)
}

/// Whether a failure this long into a statement could be the client's own read timeout rather than
/// the server dropping the connection. `MYSQL_OPT_READ_TIMEOUT` needs that much silence before it
/// fires, so anything earlier is never ours.
internal func mysqlWaitCouldOutlastSocketTimeout(
    _ waited: Duration,
    socketTimeoutSeconds: UInt32
) -> Bool {
    guard socketTimeoutSeconds > 0 else { return false }
    return waited >= .seconds(Int64(socketTimeoutSeconds))
}
