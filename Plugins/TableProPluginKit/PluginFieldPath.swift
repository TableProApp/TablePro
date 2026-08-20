import Foundation

/// A field a document store exposes at a nested path, reported for query authoring.
/// A flat column list cannot express these: a document store types a nested object as one
/// opaque column, so `address.city` never appears among its columns.
public struct PluginFieldPath: Codable, Sendable, Hashable {
    public let path: String
    public let typeName: String
    public let depth: Int

    public init(path: String, typeName: String, depth: Int) {
        self.path = path
        self.typeName = typeName
        self.depth = depth
    }
}
