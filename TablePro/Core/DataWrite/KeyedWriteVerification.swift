//
//  KeyedWriteVerification.swift
//  TablePro
//
//  The rule every keyed write is held to: more rows than expected is a fault, fewer is not.
//  MySQL reports zero affected rows for an UPDATE that writes a value a row already holds, which
//  is a normal outcome, so a keyed write is never held to `actual != expected`.
//

import Foundation

internal enum KeyedWriteVerification {
    internal static func exceedsExpectation(rowsAffected: Int, expected: Int) -> Bool {
        rowsAffected > expected
    }
}
