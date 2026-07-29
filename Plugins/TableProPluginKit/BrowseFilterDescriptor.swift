import Foundation

public struct BrowseFilterDescriptor: Sendable, Equatable {
    public struct TypeScope: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public let usesGlob: Bool
    public let caseSensitive: Bool
    public let typeScopes: [TypeScope]

    public init(usesGlob: Bool, caseSensitive: Bool, typeScopes: [TypeScope]) {
        self.usesGlob = usesGlob
        self.caseSensitive = caseSensitive
        self.typeScopes = typeScopes
    }
}

public protocol PluginBrowseFilterProvider: AnyObject {
    var browseFilterDescriptor: BrowseFilterDescriptor? { get }
}
