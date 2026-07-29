//
//  MySQLSocketTimeout.swift
//  MySQLDriverPlugin
//

internal let mysqlSocketTimeoutGraceSeconds = 30

internal func mysqlSocketTimeoutSeconds(forQueryTimeout queryTimeoutSeconds: Int) -> UInt32 {
    guard queryTimeoutSeconds > 0 else { return 0 }
    let ceiling = Int(UInt32.max) - mysqlSocketTimeoutGraceSeconds
    let clamped = min(queryTimeoutSeconds, ceiling)
    return UInt32(clamped + mysqlSocketTimeoutGraceSeconds)
}
