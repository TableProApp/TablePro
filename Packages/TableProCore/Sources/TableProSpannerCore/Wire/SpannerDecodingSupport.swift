import Foundation

internal struct SpannerFieldList: Decodable {
    let fields: [SpannerField]

    private enum CodingKeys: String, CodingKey {
        case fields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fields = try container.decodeIfPresent([SpannerField].self, forKey: .fields) ?? []
    }
}

internal extension KeyedDecodingContainer {
    func decodeFlexibleInt64IfPresent(forKey key: Key) throws -> Int64? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let text = try? decode(String.self, forKey: key) {
            return Int64(text)
        }
        return try decode(Int64.self, forKey: key)
    }

    func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
        try decodeFlexibleInt64IfPresent(forKey: key).flatMap { Int(exactly: $0) }
    }

    func decodeArrayIfPresent<Element: Decodable>(_ type: Element.Type, forKey key: Key) throws -> [Element] {
        guard contains(key), try !decodeNil(forKey: key) else { return [] }
        return try decode([Element].self, forKey: key)
    }
}
