//
//  PluginEventInfo.swift
//  TableProPluginKit
//

import Foundation

/// A scheduled event: MySQL and MariaDB's `CREATE EVENT`, run by the server's own scheduler.
///
/// Not a trigger and not a routine. A trigger fires from a row change and a routine from a call;
/// an event fires from the clock, so a dump that leaves it out restores a database whose scheduled
/// work silently stopped.
public struct PluginEventInfo: Codable, Sendable {
    public let name: String
    public let schema: String?

    /// `ONE TIME` or `RECURRING`, spelled the way the engine spells it.
    public let kind: String?

    /// What the engine reports as the next run, for display only.
    public let nextRun: String?

    public let isEnabled: Bool?

    /// The whole `CREATE EVENT` text when the listing already produced it. Never part of the
    /// event's identity: a definition that changes must not change which event this is.
    public let definition: String?

    public init(
        name: String,
        schema: String? = nil,
        kind: String? = nil,
        nextRun: String? = nil,
        isEnabled: Bool? = nil,
        definition: String? = nil
    ) {
        self.name = name
        self.schema = schema
        self.kind = kind
        self.nextRun = nextRun
        self.isEnabled = isEnabled
        self.definition = definition
    }
}
