//
//  PluginServerObject.swift
//  TableProPluginKit
//

import Foundation

public enum PluginServerObjectScope: String, Codable, Sendable {
    // Listed in every container the engine lists tables in: a MySQL database, a PostgreSQL schema.
    case container
    // Listed once per database, beside its schemas.
    case database
}

public struct PluginServerObjectKind: Codable, Sendable, Hashable {
    public let id: String
    public let displayName: String
    public let pluralDisplayName: String
    public let iconName: String
    public let scope: PluginServerObjectScope

    public init(
        id: String,
        displayName: String,
        pluralDisplayName: String,
        iconName: String,
        scope: PluginServerObjectScope = .container
    ) {
        self.id = id
        self.displayName = displayName
        self.pluralDisplayName = pluralDisplayName
        self.iconName = iconName
        self.scope = scope
    }
}

public struct PluginServerObjectInfo: Codable, Sendable {
    public let kindId: String
    public let name: String
    public let schema: String?
    // The driver's own key for reading this object again, opaque to the app.
    public let identity: String?
    // One short label drawn beside the name, such as "Recurring" or "1.3".
    public let detail: String?
    public let isEnabled: Bool?
    public let definition: String?
    public let attributes: [PluginObjectAttribute]

    public init(
        kindId: String,
        name: String,
        schema: String? = nil,
        identity: String? = nil,
        detail: String? = nil,
        isEnabled: Bool? = nil,
        definition: String? = nil,
        attributes: [PluginObjectAttribute] = []
    ) {
        self.kindId = kindId
        self.name = name
        self.schema = schema
        self.identity = identity
        self.detail = detail
        self.isEnabled = isEnabled
        self.definition = definition
        self.attributes = attributes
    }
}
