import Foundation

public struct PostgresArrayTypeInfo: Equatable, Sendable {
    public let elementTypeName: String
    public let elementTypeKind: Character

    public init(elementTypeName: String, elementTypeKind: Character) {
        self.elementTypeName = elementTypeName
        self.elementTypeKind = elementTypeKind
    }

    public var elementIsEnum: Bool { elementTypeKind == "e" }
    public var elementIsBaseType: Bool { elementTypeKind == "b" }
}

public struct PostgresTypeCatalog: Equatable, Sendable {
    public let enumLabels: [String: [String]]
    public let arrayTypes: [String: PostgresArrayTypeInfo]

    public init(enumLabels: [String: [String]], arrayTypes: [String: PostgresArrayTypeInfo]) {
        self.enumLabels = enumLabels
        self.arrayTypes = arrayTypes
    }
}

public enum PostgresColumnTypeResolver {
    public struct Resolution: Equatable, Sendable {
        public let dataType: String
        public let allowedValues: [String]?

        public init(dataType: String, allowedValues: [String]?) {
            self.dataType = dataType
            self.allowedValues = allowedValues
        }
    }

    public static func qualifiedName(schema: String?, name: String) -> String {
        guard let schema, !schema.isEmpty else { return name }
        return "\(schema).\(name)"
    }

    public static func resolve(
        rawDataType: String,
        udtSchema: String?,
        udtName: String?,
        enumLabelsByQualifiedName: [String: [String]],
        arrayTypesByQualifiedName: [String: PostgresArrayTypeInfo]
    ) -> Resolution {
        let upper = rawDataType.uppercased()
        guard let udtName, !udtName.isEmpty else {
            return Resolution(dataType: upper, allowedValues: nil)
        }
        let key = qualifiedName(schema: udtSchema, name: udtName)

        if upper == "USER-DEFINED" {
            guard let labels = enumLabelsByQualifiedName[key] else {
                return Resolution(dataType: "ENUM(\(udtName))", allowedValues: nil)
            }
            return Resolution(dataType: "ENUM", allowedValues: labels)
        }

        guard upper == "ARRAY", let arrayType = arrayTypesByQualifiedName[key] else {
            return Resolution(dataType: upper, allowedValues: nil)
        }

        if arrayType.elementIsEnum {
            let elementKey = qualifiedName(schema: udtSchema, name: arrayType.elementTypeName)
            guard let labels = enumLabelsByQualifiedName[elementKey] else {
                return Resolution(dataType: "ENUM[](\(arrayType.elementTypeName))", allowedValues: nil)
            }
            return Resolution(dataType: "ENUM[]", allowedValues: labels)
        }

        guard arrayType.elementIsBaseType else {
            return Resolution(dataType: upper, allowedValues: nil)
        }
        return Resolution(dataType: "\(arrayType.elementTypeName)[]", allowedValues: nil)
    }
}
