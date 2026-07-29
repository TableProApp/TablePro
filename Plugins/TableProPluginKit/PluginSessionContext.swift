//
//  PluginSessionContext.swift
//  TableProPluginKit
//
//  A switchable session dimension a driver exposes beyond database and schema,
//  such as a Snowflake warehouse or role. The app renders one toolbar picker
//  per context and routes selections back through switchSessionContext.
//

import Foundation

public struct PluginSessionContext: Codable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let iconName: String
    public let currentValue: String?
    public let availableValues: [String]

    public init(
        id: String,
        label: String,
        iconName: String,
        currentValue: String?,
        availableValues: [String]
    ) {
        self.id = id
        self.label = label
        self.iconName = iconName
        self.currentValue = currentValue
        self.availableValues = availableValues
    }
}
