import Foundation

/// A field a document store exposes at a nested path, reported for query authoring.
/// A flat column list cannot express these: a document store types a nested object as one
/// opaque column, so `address.city` never appears among its columns.
public struct PluginFieldPath: Codable, Sendable, Hashable {
    public let path: String
    public let typeName: String
    public let depth: Int

    /// Ancestor paths that hold an array, outermost first. `items.sku` reports `["items"]`,
    /// `customer.country` reports none. A query on a path with an array ancestor matches when
    /// *any* element satisfies it, so a caller that needs several conditions to hold on the
    /// *same* element has to know which prefix to bind them to.
    public let arrayPrefixes: [String]

    @_disfavoredOverload
    public init(path: String, typeName: String, depth: Int) {
        self.path = path
        self.typeName = typeName
        self.depth = depth
        self.arrayPrefixes = []
    }

    public init(path: String, typeName: String, depth: Int, arrayPrefixes: [String]) {
        self.path = path
        self.typeName = typeName
        self.depth = depth
        self.arrayPrefixes = arrayPrefixes
    }

    enum CodingKeys: String, CodingKey {
        case path, typeName, depth, arrayPrefixes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decode(String.self, forKey: .path)
        self.typeName = try container.decode(String.self, forKey: .typeName)
        self.depth = try container.decode(Int.self, forKey: .depth)
        self.arrayPrefixes = try container.decodeIfPresent([String].self, forKey: .arrayPrefixes) ?? []
    }
}
