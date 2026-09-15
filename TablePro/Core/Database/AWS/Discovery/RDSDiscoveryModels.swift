import Foundation

struct RDSInstanceEndpoint: Sendable, Equatable {
    let address: String?
    let port: Int?
}

struct RDSInstance: Sendable, Equatable {
    let identifier: String
    let engine: String
    let engineVersion: String?
    let status: String?
    let endpoint: RDSInstanceEndpoint?
    let databaseName: String?
    let adminUsername: String?
    let clusterIdentifier: String?
    let iamAuthenticationEnabled: Bool
    let isPubliclyAccessible: Bool
}

struct RDSClusterMember: Sendable, Equatable {
    let instanceIdentifier: String
    let isWriter: Bool
}

struct RDSCluster: Sendable, Equatable {
    let identifier: String
    let engine: String
    let engineVersion: String?
    let status: String?
    let endpoint: String?
    let readerEndpoint: String?
    let port: Int?
    let databaseName: String?
    let adminUsername: String?
    let iamAuthenticationEnabled: Bool
    let members: [RDSClusterMember]
}

enum DiscoveredDatabaseKind: String, Sendable, Equatable {
    case instance
    case clusterWriter
    case clusterReader
}

struct DiscoveredDatabase: Sendable, Equatable, Identifiable {
    let region: String
    let identifier: String
    let kind: DiscoveredDatabaseKind
    let engine: String
    let engineVersion: String?
    let status: String?
    let host: String?
    let port: Int?
    let databaseName: String?
    let adminUsername: String?
    let iamAuthenticationEnabled: Bool
    let isPubliclyAccessible: Bool

    var id: String { "\(region)|\(kind.rawValue)|\(identifier)" }

    var isImportable: Bool {
        guard let host, !host.isEmpty else { return false }
        return true
    }
}
