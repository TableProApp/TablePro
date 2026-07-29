//
//  TeamLibraryModels.swift
//  TablePro
//
//  Transfer types for the backend-hosted team library. Requests use snake_case keys via CodingKeys
//  so the embedded ExportableConnection payload keeps its own key encoding (no recursive key strategy).
//

import Foundation
import TableProImport

struct TeamLibraryPullRequest: Codable {
    let licenseKey: String
    let machineId: String

    enum CodingKeys: String, CodingKey {
        case licenseKey = "license_key"
        case machineId = "machine_id"
    }
}

struct TeamLibraryConnectionPayload: Codable {
    let sourceConnectionId: String?
    let payload: ExportableConnection

    enum CodingKeys: String, CodingKey {
        case sourceConnectionId = "source_connection_id"
        case payload
    }
}

struct TeamLibraryQueryFolderPayload: Codable {
    let clientId: String
    let parentClientId: String?
    let name: String
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case parentClientId = "parent_client_id"
        case name
        case sortOrder = "sort_order"
    }
}

struct TeamLibraryQueryPayload: Codable {
    let clientId: String
    let folderClientId: String?
    let connectionClientId: String?
    let name: String
    let query: String
    let keyword: String?
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case folderClientId = "folder_client_id"
        case connectionClientId = "connection_client_id"
        case name
        case query
        case keyword
        case sortOrder = "sort_order"
    }
}

struct TeamLibraryPublishRequest: Codable {
    let licenseKey: String
    let machineId: String
    let connections: [TeamLibraryConnectionPayload]
    let queryFolders: [TeamLibraryQueryFolderPayload]
    let queries: [TeamLibraryQueryPayload]

    enum CodingKeys: String, CodingKey {
        case licenseKey = "license_key"
        case machineId = "machine_id"
        case connections
        case queryFolders = "query_folders"
        case queries
    }
}

struct TeamLibraryPublishResponse: Codable {
    let publishedAt: String
    let connectionCount: Int
    let queryCount: Int

    enum CodingKeys: String, CodingKey {
        case publishedAt = "published_at"
        case connectionCount = "connection_count"
        case queryCount = "query_count"
    }
}

struct TeamLibraryPullResponse: Codable {
    let connections: [Connection]
    let queryFolders: [QueryFolder]
    let queries: [Query]
    let fetchedAt: String

    enum CodingKeys: String, CodingKey {
        case connections
        case queryFolders = "query_folders"
        case queries
        case fetchedAt = "fetched_at"
    }

    static let empty = TeamLibraryPullResponse(connections: [], queryFolders: [], queries: [], fetchedAt: "")

    struct Connection: Codable, Identifiable {
        let id: String
        let sourceConnectionId: String?
        let payload: ExportableConnection
        let publishedBy: String?
        let publishedAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case sourceConnectionId = "source_connection_id"
            case payload
            case publishedBy = "published_by"
            case publishedAt = "published_at"
        }
    }

    struct QueryFolder: Codable, Identifiable {
        var id: String { clientId }
        let clientId: String
        let parentClientId: String?
        let name: String
        let sortOrder: Int
        let publishedBy: String?

        enum CodingKeys: String, CodingKey {
            case clientId = "client_id"
            case parentClientId = "parent_client_id"
            case name
            case sortOrder = "sort_order"
            case publishedBy = "published_by"
        }
    }

    struct Query: Codable, Identifiable {
        var id: String { clientId }
        let clientId: String
        let folderClientId: String?
        let connectionClientId: String?
        let name: String
        let query: String
        let keyword: String?
        let sortOrder: Int
        let publishedBy: String?

        enum CodingKeys: String, CodingKey {
            case clientId = "client_id"
            case folderClientId = "folder_client_id"
            case connectionClientId = "connection_client_id"
            case name
            case query
            case keyword
            case sortOrder = "sort_order"
            case publishedBy = "published_by"
        }
    }
}
