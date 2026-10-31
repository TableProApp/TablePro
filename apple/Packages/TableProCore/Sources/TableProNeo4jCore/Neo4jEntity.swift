import Foundation

public enum Neo4jStructureTag {
    public static let node: UInt8 = 0x4E
    public static let relationship: UInt8 = 0x52
    public static let unboundRelationship: UInt8 = 0x72
    public static let path: UInt8 = 0x50
    public static let date: UInt8 = 0x44
    public static let time: UInt8 = 0x54
    public static let localTime: UInt8 = 0x74
    public static let dateTime: UInt8 = 0x49
    public static let dateTimeZoneId: UInt8 = 0x69
    public static let legacyDateTime: UInt8 = 0x46
    public static let legacyDateTimeZoneId: UInt8 = 0x66
    public static let localDateTime: UInt8 = 0x64
    public static let duration: UInt8 = 0x45
    public static let point2D: UInt8 = 0x58
    public static let point3D: UInt8 = 0x59
}

/// A node or relationship as the grid sees it. Bolt 4 has no element id, so the numeric id
/// stands in, written as text either way.
public struct Neo4jEntity: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case node(labels: [String])
        case relationship(type: String, startId: String, endId: String)
    }

    public let elementId: String
    public let kind: Kind
    public let properties: [String: PackStreamValue]

    public init(elementId: String, kind: Kind, properties: [String: PackStreamValue]) {
        self.elementId = elementId
        self.kind = kind
        self.properties = properties
    }

    public init?(_ value: PackStreamValue) {
        guard case .structure(let tag, let fields) = value else { return nil }
        switch tag {
        case Neo4jStructureTag.node where fields.count >= 3:
            elementId = Self.identifier(fields, elementIdIndex: 3, idIndex: 0)
            kind = .node(labels: fields[1].listValue?.compactMap(\.stringValue) ?? [])
            properties = fields[2].mapValue ?? [:]
        case Neo4jStructureTag.relationship where fields.count >= 5:
            elementId = Self.identifier(fields, elementIdIndex: 5, idIndex: 0)
            kind = .relationship(
                type: fields[3].stringValue ?? "",
                startId: Self.identifier(fields, elementIdIndex: 6, idIndex: 1),
                endId: Self.identifier(fields, elementIdIndex: 7, idIndex: 2)
            )
            properties = fields[4].mapValue ?? [:]
        default:
            return nil
        }
    }

    private static func identifier(_ fields: [PackStreamValue], elementIdIndex: Int, idIndex: Int) -> String {
        if elementIdIndex < fields.count, let elementId = fields[elementIdIndex].stringValue {
            return elementId
        }
        return fields[idIndex].intValue.map(String.init) ?? ""
    }
}
