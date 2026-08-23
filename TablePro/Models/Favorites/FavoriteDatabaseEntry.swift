//
//  FavoriteDatabaseEntry.swift
//  TablePro
//

import Foundation

internal struct FavoriteDatabaseEntry: Codable, Hashable, Identifiable, Sendable {
    internal let connectionId: UUID
    internal let database: String
    internal let environment: FavoriteDatabaseEnvironment

    internal var id: String {
        "\(connectionId.uuidString)\u{1}\(database)"
    }

    internal init(
        connectionId: UUID,
        database: String,
        environment: FavoriteDatabaseEnvironment
    ) {
        self.connectionId = connectionId
        self.database = database
        self.environment = environment
    }

    private enum CodingKeys: String, CodingKey {
        case connectionId
        case database
        case environment
    }

    internal init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connectionId = try container.decode(UUID.self, forKey: .connectionId)
        database = try container.decode(String.self, forKey: .database)
        let rawEnvironment = try container.decodeIfPresent(String.self, forKey: .environment)
        environment = rawEnvironment.flatMap(FavoriteDatabaseEnvironment.init(rawValue:)) ?? .unassigned
    }
}
