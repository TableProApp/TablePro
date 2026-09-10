//
//  RewindRefusal.swift
//  TablePro
//
//  Why a committed write cannot be taken back.
//
//  Every one of these is a case where TablePro does not know enough to restore the row exactly,
//  and the honest answer is to say so rather than to write something close. A rewind that gets a
//  row nearly right is worse than one that refuses, because the user believes the first one.
//

import Foundation

enum RewindRefusal: String, Codable, Sendable, Equatable, CaseIterable {
    /// The table has no primary key, so the pre-image cannot name one row.
    case noPrimaryKey
    /// The save also truncated or dropped a table, which no record of rows can undo.
    case destructiveTableOperation
    /// A column was written with `DEFAULT` or a function like `NOW()`, so the value the server
    /// stored was never read back and the row's after-state is unknown.
    case serverComputedValue
    /// The row was inserted and the server chose its key, which the app never read back.
    case serverAssignedKey
    /// The value was larger than the capture limit, so it was never stored.
    case valueTooLarge
    /// The driver writes its own statements and cannot insert a row with the key it used to have.
    case identityNotPreservable
    /// The connection or table the record names is not reachable any more.
    case targetUnavailable
    /// The key is binary or otherwise cannot be written as a filter, so the row cannot be read
    /// back and checked before writing to it.
    case keyNotComparable

    var explanation: String {
        switch self {
        case .noPrimaryKey:
            return String(localized: "The table has no primary key, so this row cannot be identified.")
        case .destructiveTableOperation:
            return String(localized: "The save also truncated or dropped a table.")
        case .serverComputedValue:
            return String(localized: "A column was set to a default or a function, so its stored value is unknown.")
        case .serverAssignedKey:
            return String(localized: "The server chose this row's key.")
        case .valueTooLarge:
            return String(localized: "A value was too large to keep.")
        case .identityNotPreservable:
            return String(localized: "This database cannot restore a row with its original key.")
        case .targetUnavailable:
            return String(localized: "The table is no longer reachable.")
        case .keyNotComparable:
            return String(localized: "This row's key cannot be matched, so it cannot be checked before writing.")
        }
    }
}
