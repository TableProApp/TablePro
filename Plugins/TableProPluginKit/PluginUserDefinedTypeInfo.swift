//
//  PluginUserDefinedTypeInfo.swift
//  TableProPluginKit
//
//  Transfer type describing a named type the user created: an enum, a composite, a domain or a
//  range. Engines without named types never produce one.
//

import Foundation

public enum PluginUserDefinedTypeKind: String, Codable, Sendable {
    case enumeration = "enum"
    case composite
    case domain
    case range
}

public struct PluginUserDefinedTypeField: Codable, Sendable, Hashable {
    public let name: String
    public let type: String

    /// A collation of the field's own, already quoted, when it differs from the type's default.
    public let collation: String?

    public init(name: String, type: String, collation: String? = nil) {
        self.name = name
        self.type = type
        self.collation = collation
    }
}

/// Where a new enum label goes. PostgreSQL appends by default and takes one neighbour to place it
/// before or after; it never reorders an existing label.
public struct PluginEnumLabelPlacement: Codable, Sendable, Hashable {
    public let anchor: String
    public let placesBefore: Bool

    public init(anchor: String, placesBefore: Bool) {
        self.anchor = anchor
        self.placesBefore = placesBefore
    }
}

public struct PluginUserDefinedTypeInfo: Codable, Sendable {
    public let name: String
    public let schema: String?
    public let kind: PluginUserDefinedTypeKind

    /// Whatever the driver needs to address this exact type again: a PostgreSQL oid. Opaque to
    /// the app, which only ever hands it back.
    public let identity: String?

    /// The labels in declaration order. Enums only.
    public let enumLabels: [String]

    /// The fields in declaration order. Composites only.
    public let fields: [PluginUserDefinedTypeField]

    /// A domain's base type, or a range's subtype, spelled the way the engine spells it.
    public let baseType: String?

    /// How a column definition names this type, qualified and quoted by the engine itself. The
    /// engine knows its own reserved words and folding rules; nothing above it should guess.
    public let columnTypeSpelling: String?

    /// The CREATE statement, when the same read that listed the type already produced it. Never
    /// part of the type's identity.
    public let definition: String?

    public let attributes: [PluginObjectAttribute]

    public init(
        name: String,
        kind: PluginUserDefinedTypeKind,
        schema: String? = nil,
        identity: String? = nil,
        enumLabels: [String] = [],
        fields: [PluginUserDefinedTypeField] = [],
        baseType: String? = nil,
        columnTypeSpelling: String? = nil,
        definition: String? = nil,
        attributes: [PluginObjectAttribute] = []
    ) {
        self.name = name
        self.kind = kind
        self.schema = schema
        self.identity = identity
        self.enumLabels = enumLabels
        self.fields = fields
        self.baseType = baseType
        self.columnTypeSpelling = columnTypeSpelling
        self.definition = definition
        self.attributes = attributes
    }
}
