//
//  PluginUserDefinedTypeChange.swift
//  TableProPluginKit
//

import Foundation

/// A check constraint the user wrote: the boolean expression only, which the engine wraps in its
/// own syntax. A nil or empty name lets the engine pick one.
public struct PluginUserDefinedTypeCheck: Codable, Sendable, Hashable {
    public let name: String?
    public let expression: String

    public init(name: String?, expression: String) {
        self.name = name
        self.expression = expression
    }
}

/// One alteration of an existing named type, in the order the user queued it.
///
/// Not `@frozen`, so an engine with more to alter can add a case. A driver answers nil for a case it
/// cannot express, and the app reads that answer to decide what to offer.
public enum PluginUserDefinedTypeChange: Sendable, Hashable {
    case rename(to: String)
    /// Nil or empty removes the comment.
    case setComment(String?)
    case addEnumLabel(String, placement: PluginEnumLabelPlacement?)
    case renameEnumLabel(from: String, to: String)
    /// A domain's default. Nil removes it.
    case setDefault(String?)
    case setNotNull(Bool)
    /// `validatesExistingValues` false adds the check without scanning stored values.
    case addCheck(PluginUserDefinedTypeCheck, validatesExistingValues: Bool)
    case dropConstraint(String)
    case validateConstraint(String)
    case addField(PluginUserDefinedTypeField)
    case dropField(String)
    case renameField(from: String, to: String)
    case changeFieldType(field: String, type: String)
}

/// What a new named type is made of. Only the members its kind reads are used.
public struct PluginUserDefinedTypeDefinition: Codable, Sendable, Hashable {
    public let name: String
    public let schema: String?
    public let kind: PluginUserDefinedTypeKind
    public let enumLabels: [String]
    public let fields: [PluginUserDefinedTypeField]
    public let baseType: String?
    public let defaultValue: String?
    public let isNotNull: Bool
    public let checks: [PluginUserDefinedTypeCheck]
    public let comment: String?

    public init(
        name: String,
        schema: String?,
        kind: PluginUserDefinedTypeKind,
        enumLabels: [String] = [],
        fields: [PluginUserDefinedTypeField] = [],
        baseType: String? = nil,
        defaultValue: String? = nil,
        isNotNull: Bool = false,
        checks: [PluginUserDefinedTypeCheck] = [],
        comment: String? = nil
    ) {
        self.name = name
        self.schema = schema
        self.kind = kind
        self.enumLabels = enumLabels
        self.fields = fields
        self.baseType = baseType
        self.defaultValue = defaultValue
        self.isNotNull = isNotNull
        self.checks = checks
        self.comment = comment
    }
}
