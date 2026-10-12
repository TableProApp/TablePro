import Foundation

public struct ImportLibrarySnapshot: Sendable {
    public struct Connection: Sendable {
        public let id: UUID
        public let name: String
        public let matchKey: ConnectionMatchKey

        public init(id: UUID, name: String, matchKey: ConnectionMatchKey) {
            self.id = id
            self.name = name
            self.matchKey = matchKey
        }
    }

    public var connections: [Connection]
    public var savedQueries: [SavedQueryLedger.Entry]

    public init(connections: [Connection] = [], savedQueries: [SavedQueryLedger.Entry] = []) {
        self.connections = connections
        self.savedQueries = savedQueries
    }
}

public struct ImportRules: Sendable, Equatable {
    public var maximumGroupDepth: Int
    public var supportsSavedQueries: Bool
    public var supportsCredentialProfiles: Bool

    public init(maximumGroupDepth: Int, supportsSavedQueries: Bool, supportsCredentialProfiles: Bool) {
        self.maximumGroupDepth = maximumGroupDepth
        self.supportsSavedQueries = supportsSavedQueries
        self.supportsCredentialProfiles = supportsCredentialProfiles
    }
}

public struct ImportEnvironment: Sendable {
    public var rules: ImportRules
    public var registeredTypeIds: Set<String>
    public var missingDriverNames: [String: String]
    public var fileExists: @Sendable (String) -> Bool

    public init(
        rules: ImportRules,
        registeredTypeIds: Set<String>,
        missingDriverNames: [String: String] = [:],
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.rules = rules
        self.registeredTypeIds = registeredTypeIds
        self.missingDriverNames = missingDriverNames
        self.fileExists = fileExists
    }
}
