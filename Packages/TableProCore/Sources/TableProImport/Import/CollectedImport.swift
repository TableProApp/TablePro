import Foundation

public enum ImportSource: Sendable, Equatable {
    case file(name: String)
    case foreignApp(name: String)
    case link
    case cloudDiscovery(name: String)

    /// A discovered endpoint carries only part of a connection, so it must never overwrite a full one.
    public var offersReplace: Bool {
        if case .cloudDiscovery = self { return false }
        return true
    }
}

public struct OversizedSavedQuery: Sendable, Equatable {
    public let ref: BundleRef
    public let name: String
    public let folderPath: [String]
    public let connection: BundleRef?
    public let byteCount: Int

    public init(ref: BundleRef, name: String, folderPath: [String], connection: BundleRef?, byteCount: Int) {
        self.ref = ref
        self.name = name
        self.folderPath = folderPath
        self.connection = connection
        self.byteCount = byteCount
    }
}

public struct CollectedImport: Sendable {
    public let bundle: ConnectionBundle
    public let source: ImportSource
    public let unsuggestedConnections: Set<BundleRef>
    public let unsuggestedQueries: Set<BundleRef>
    public let oversizedQueries: [OversizedSavedQuery]
    public let credentialsAborted: Bool

    public init(
        bundle: ConnectionBundle,
        source: ImportSource,
        unsuggestedConnections: Set<BundleRef> = [],
        unsuggestedQueries: Set<BundleRef> = [],
        oversizedQueries: [OversizedSavedQuery] = [],
        credentialsAborted: Bool = false
    ) {
        self.bundle = bundle
        self.source = source
        self.unsuggestedConnections = unsuggestedConnections
        self.unsuggestedQueries = unsuggestedQueries
        self.oversizedQueries = oversizedQueries
        self.credentialsAborted = credentialsAborted
    }
}
