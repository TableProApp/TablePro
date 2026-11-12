//
//  KeyedWriteVerification.swift
//  TablePro
//
//  The rule every keyed write is held to: more rows than expected is a fault. Fewer is one only
//  for an UPDATE on an engine whose count is the rows it matched (`DataWriteRowCounts`): MySQL
//  reports zero affected rows for an UPDATE that writes a value a row already holds.
//

import Foundation

internal enum KeyedWriteVerification {
    internal static func exceedsExpectation(rowsAffected: Int, expected: Int) -> Bool {
        rowsAffected > expected
    }
}
