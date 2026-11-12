//
//  KeyedWriteVerification.swift
//  TablePro
//
//  The rule every keyed write is held to: more rows than expected is a fault. Fewer is one only
//  for an UPDATE whose count is the rows it matched (`DataWriteRowCounts`): a DELETE that found its
//  row already gone left the table as the user wanted it.
//

import Foundation

internal enum KeyedWriteVerification {
    internal static func exceedsExpectation(rowsAffected: Int, expected: Int) -> Bool {
        rowsAffected > expected
    }
}
