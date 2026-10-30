//
//  PluginSessionScope.swift
//  TableProPluginKit
//

import Foundation

/// Why a caller holds a session's settings for a stretch of work. Not `@frozen`, so a purpose can be added.
public enum PluginSessionPurpose: Sendable, Equatable {
    /// Statements the caller does not write run inside, such as an imported file's `SET`s. Closing puts back the
    /// settings the driver saved, the ones dump files change; anything else the statements left stays.
    case preserve

    /// Rows and definitions are read for a database of the same engine to take back unchanged: a dump, or the source
    /// side of a copy.
    case verbatimRead

    /// Rows read under `verbatimRead` are written back: the target side of a copy. A driver pins the same
    /// representation for both purposes, so a value read under one is written under the other unchanged.
    case verbatimWrite

    /// Rows arrive in an order the target's foreign keys may refuse. The driver turns off the checks it can for this
    /// session, changing nothing else the writes do, and closing puts back what it saved. Nil when it cannot.
    case relaxedForeignKeys
}

/// One session setting, named and spelled the way its driver reads and writes it. A nil value is SQL `NULL`.
public struct PluginSessionSetting: Sendable, Equatable {
    public let name: String
    public let value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }
}

/// What `openSessionScope(for:)` saved and set on one session. Only the driver that opened it reads `saved`.
///
/// Not `@frozen`, so it can gain a field; a new field arrives with its own initializer overload.
public struct PluginSessionScope: Sendable, Equatable {
    public let purpose: PluginSessionPurpose
    public let saved: [PluginSessionSetting]
    public let applied: [PluginSessionSetting]

    public init(purpose: PluginSessionPurpose, saved: [PluginSessionSetting], applied: [PluginSessionSetting]) {
        self.purpose = purpose
        self.saved = saved
        self.applied = applied
    }

    /// The value this scope set for `name`, matched case-insensitively, or nil when it set nothing by that name.
    public func appliedValue(of name: String) -> String? {
        applied.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Statements written around another one, such as the `SET`s that recreate a routine under the `sql_mode` the server
/// recorded for it and then put the script's own mode back.
public struct PluginStatementScope: Sendable, Equatable {
    public let opening: [String]
    public let closing: [String]

    public init(opening: [String], closing: [String]) {
        self.opening = opening
        self.closing = closing
    }
}
