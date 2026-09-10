//
//  UserDefinedTypeInfo.swift
//  TablePro
//

import Foundation

/// Where a new enum label goes relative to an existing one. Absent, the label is appended.
struct EnumLabelPlacement: Hashable, Sendable {
    let anchor: String
    let placesBefore: Bool
}

struct UserDefinedTypeInfo: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case enumeration = "enum"
        case composite
        case domain
        case range
        case other

        var displayName: String {
            switch self {
            case .enumeration: return String(localized: "Enum Type")
            case .composite:   return String(localized: "Composite Type")
            case .domain:      return String(localized: "Domain")
            case .range:       return String(localized: "Range Type")
            case .other:       return String(localized: "Type")
            }
        }

        var iconName: String {
            switch self {
            case .enumeration: return "list.bullet"
            case .composite:   return "rectangle.split.3x1"
            case .domain:      return "checkmark.seal"
            case .range:       return "arrow.left.and.right.square"
            case .other:       return SidebarObjectKind.type.iconName
            }
        }
    }

    struct Field: Hashable, Sendable {
        let name: String
        let type: String
        let collation: String?

        init(name: String, type: String, collation: String? = nil) {
            self.name = name
            self.type = type
            self.collation = collation
        }
    }

    let name: String
    let schema: String?
    let kind: Kind

    /// The driver's own key for re-addressing this type when asked for its definition. Opaque here.
    let identity: String?
    let enumLabels: [String]
    let fields: [Field]

    /// A domain's base type, or a range's subtype.
    let baseType: String?

    /// How a column definition names this type, as the engine itself spells it.
    let columnTypeSpelling: String?

    /// The CREATE statement, when the listing already returned it. Never part of `id`.
    let definition: String?
    let attributes: [ObjectAttribute]

    init(
        name: String,
        kind: Kind,
        schema: String? = nil,
        identity: String? = nil,
        enumLabels: [String] = [],
        fields: [Field] = [],
        baseType: String? = nil,
        columnTypeSpelling: String? = nil,
        definition: String? = nil,
        attributes: [ObjectAttribute] = []
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

    var qualifiedName: String {
        guard let schema, !schema.isEmpty else { return name }
        return "\(schema).\(name)"
    }

    /// A type name is unique within its schema on every engine that has named types, so the
    /// qualified name is the whole identity. The definition and the labels are deliberately left
    /// out: an edited enum must still be the same row.
    var id: String {
        "type_\(qualifiedName)"
    }

    static func == (lhs: UserDefinedTypeInfo, rhs: UserDefinedTypeInfo) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
