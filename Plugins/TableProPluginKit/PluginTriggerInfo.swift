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

    public init(
        name: String,
        timing: String,
        event: String,
        statement: String
    ) {
        self.name = name
        self.timing = timing
        self.event = event
        self.statement = statement
    }
}
