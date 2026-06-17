//
//  PluginTriggerInfo.swift
//  TableProPluginKit
//
//  Transfer type describing a database trigger.
//

import Foundation

public struct PluginTriggerInfo: Codable, Sendable {
    public let name: String
    public let timing: String
    public let event: String
    public let statement: String
    public let enabled: Bool?
    public let orientation: String?
    public let whenClause: String?

    public init(
        name: String,
        timing: String,
        event: String,
        statement: String,
        enabled: Bool? = nil,
        orientation: String? = nil,
        whenClause: String? = nil
    ) {
        self.name = name
        self.timing = timing
        self.event = event
        self.statement = statement
        self.enabled = enabled
        self.orientation = orientation
        self.whenClause = whenClause
    }

    @_disfavoredOverload
    public init(
        name: String,
        timing: String,
        event: String,
        statement: String
    ) {
        self.init(name: name, timing: timing, event: event, statement: statement, enabled: nil, orientation: nil, whenClause: nil)
    }
}
