//
//  PluginUserDefinedTypeInfo.swift
//  TableProPluginKit
//
//  Transfer type describing a named type the user created. Engines without named types never
//  produce one.
//

import Foundation

/// Deliberately not `@frozen`, so it can take a case for each engine's own shape as drivers arrive.
/// Every app-side switch over it carries `@unknown default`, which is what makes a new case additive
/// rather than breaking, the same growth path `PluginCapability` uses.
///
/// A kind names the shape, not the engine's word for it. SQL Server's alias type is a named type
/// over a base type, which is what `domain` already describes, but a reader on SQL Server has never
/// heard the word domain and calling it one would be wrong on screen rather than merely imprecise.
public enum PluginUserDefinedTypeKind: String, Codable, Sendable {
    case enumeration = "enum"
    case composite
    case domain
    case range

    /// SQL Server `CREATE TYPE x FROM base`: a base type, a length and a nullability, nothing else.
    case aliasType

    /// SQL Server `CREATE TYPE x AS TABLE (...)`: columns rather than fields, and only usable as a
    /// table-valued parameter, never as a column type.
    case tableType

    /// SQL Server `CREATE TYPE x EXTERNAL NAME assembly.class`. Its definition lives in a .NET
    /// assembly, so no catalog read can produce its source.
    case clrType
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

    /// Fills in the schema the read was scoped to when the driver did not name one, so a type's
    /// qualified name is never bare. A driver that did name one keeps it: a type moved to another
    /// schema still reports where it actually lives.
    public func adoptingSchema(_ fallback: String?) -> PluginUserDefinedTypeInfo {
        guard schema?.isEmpty ?? true, let fallback, !fallback.isEmpty else { return self }
        return PluginUserDefinedTypeInfo(
            name: name,
            kind: kind,
            schema: fallback,
            identity: identity,
            enumLabels: enumLabels,
            fields: fields,
            baseType: baseType,
            columnTypeSpelling: columnTypeSpelling,
            definition: definition,
            attributes: attributes
        )
    }
}
