//
//  PluginStatementContext.swift
//  TableProPluginKit
//

import Foundation

/// What the host decided about a statement before handing it to a driver.
///
/// Deliberately not `@frozen`, and every field is a `var` with a default set through `init()`, so a later field is
/// one more property rather than a second initializer every already-built plugin would have to find.
public struct PluginStatementContext: Sendable, Equatable {
    /// The host proved from the statement's text that it only reads, and ran it on that basis: Safe Mode skipped its
    /// write confirmation, or a read-only client was allowed to send it. A driver whose statements can do more than
    /// their text shows, such as one that evaluates them in a scripting engine with state, refuses every write while
    /// running a statement marked this way.
    public var readOnly = false

    public init() {}
}
