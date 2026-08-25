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

    /// The table the trigger fires for. A per-table fetch already knows it, but a schema-wide list
    /// cannot be grouped, labelled or navigated back to its table without it.
    public let table: String?
    public let schema: String?

    /// ROW or STATEMENT, spelled the way the engine spells it.
    public let orientation: String?

    /// The whole CREATE TRIGGER text when the engine can produce one. `statement` is only the
    /// action body, which is not a runnable definition on its own.
    public let definition: String?

    public let attributes: [PluginObjectAttribute]

    public init(
        name: String,
        table: String?,
        schema: String? = nil,
        timing: String,
        event: String,
        orientation: String? = nil,
        statement: String,
        definition: String? = nil,
        enabled: Bool? = nil,
        attributes: [PluginObjectAttribute] = []
    ) {
        self.name = name
        self.table = table
        self.schema = schema
        self.timing = timing
        self.event = event
        self.orientation = orientation
        self.statement = statement
        self.definition = definition
        self.enabled = enabled
        self.attributes = attributes
    }

    @_disfavoredOverload
    public init(
        name: String,
        timing: String,
        event: String,
        statement: String,
        enabled: Bool? = nil
    ) {
        self.name = name
        self.timing = timing
        self.event = event
        self.statement = statement
        self.enabled = enabled
        self.table = nil
        self.schema = nil
        self.orientation = nil
        self.definition = nil
        self.attributes = []
    }

    public func adopting(table: String?, schema: String?) -> PluginTriggerInfo {
        PluginTriggerInfo(
            name: name,
            table: self.table ?? table,
            schema: self.schema ?? schema,
            timing: timing,
            event: event,
            orientation: orientation,
            statement: statement,
            definition: definition,
            enabled: enabled,
            attributes: attributes
        )
    }
}
