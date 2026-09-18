import Foundation

public struct SpannerType: Codable, Sendable, Hashable {
    public static let unspecifiedCode = "TYPE_CODE_UNSPECIFIED"

    public let code: String
    public let typeAnnotation: String?
    public let structFields: [SpannerField]
    private let elementStorage: [SpannerType]

    public var arrayElementType: SpannerType? {
        elementStorage.first
    }

    public init(
        code: String,
        arrayElementType: SpannerType? = nil,
        structFields: [SpannerField] = [],
        typeAnnotation: String? = nil
    ) {
        self.code = code
        self.typeAnnotation = typeAnnotation
        self.structFields = structFields
        self.elementStorage = arrayElementType.map { [$0] } ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case arrayElementType
        case structType
        case typeAnnotation
    }

    private enum StructTypeKeys: String, CodingKey {
        case fields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(String.self, forKey: .code) ?? Self.unspecifiedCode
        typeAnnotation = try container.decodeIfPresent(String.self, forKey: .typeAnnotation)
        elementStorage = try container.decodeIfPresent(SpannerType.self, forKey: .arrayElementType).map { [$0] } ?? []
        structFields = try Self.decodeStructFields(container)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encodeIfPresent(typeAnnotation, forKey: .typeAnnotation)
        try container.encodeIfPresent(arrayElementType, forKey: .arrayElementType)
        guard code == "STRUCT" || !structFields.isEmpty else { return }
        var structContainer = container.nestedContainer(keyedBy: StructTypeKeys.self, forKey: .structType)
        try structContainer.encode(structFields, forKey: .fields)
    }

    private static func decodeStructFields(_ container: KeyedDecodingContainer<CodingKeys>) throws -> [SpannerField] {
        guard container.contains(.structType), try !container.decodeNil(forKey: .structType) else { return [] }
        let structContainer = try container.nestedContainer(keyedBy: StructTypeKeys.self, forKey: .structType)
        return try structContainer.decodeIfPresent([SpannerField].self, forKey: .fields) ?? []
    }
}

public struct SpannerField: Codable, Sendable, Hashable {
    public let name: String
    public let type: SpannerType

    public init(name: String, type: SpannerType) {
        self.name = name
        self.type = type
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try container.decodeIfPresent(SpannerType.self, forKey: .type) ?? SpannerType(code: SpannerType.unspecifiedCode)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
    }
}
