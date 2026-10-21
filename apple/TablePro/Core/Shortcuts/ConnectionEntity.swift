//
//  ConnectionEntity.swift
//  TablePro
//

import AppIntents
import Foundation

@available(macOS 14.0, *)
internal struct ConnectionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Connection")
    static let defaultQuery = ConnectionEntityQuery()

    var id: UUID
    var name: String
    var host: String
    var databaseType: String

    var displayRepresentation: DisplayRepresentation {
        guard !databaseType.isEmpty else { return DisplayRepresentation(title: "\(name)") }
        guard !host.isEmpty else { return DisplayRepresentation(title: "\(name)", subtitle: "\(databaseType)") }
        return DisplayRepresentation(title: "\(name)", subtitle: "\(databaseType), \(host)")
    }

    init(id: UUID, name: String, host: String, databaseType: String) {
        self.id = id
        self.name = name
        self.host = host
        self.databaseType = databaseType
    }

    init(listing: ExternalConnectionListing) {
        self.init(
            id: listing.id,
            name: listing.name.isEmpty ? listing.host : listing.name,
            host: listing.host,
            databaseType: listing.databaseType
        )
    }
}

@available(macOS 14.0, *)
internal struct ConnectionEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ConnectionEntity] {
        await MainActor.run {
            Self.entities(
                for: identifiers,
                listings: ExternalConnectionDirectory.listings(),
                stored: ConnectionStorage.shared.loadConnections()
            )
        }
    }

    func suggestedEntities() async throws -> [ConnectionEntity] {
        await MainActor.run { ExternalConnectionDirectory.listings().map(ConnectionEntity.init(listing:)) }
    }

    // A connection blocked after a shortcut picked it still resolves, by name only, so running the shortcut says why
    // it stopped instead of asking for a connection again.
    static func entities(
        for identifiers: [UUID],
        listings: [ExternalConnectionListing],
        stored: [DatabaseConnection]
    ) -> [ConnectionEntity] {
        let listed = Dictionary(listings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let saved = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { id in
            if let listing = listed[id] {
                return ConnectionEntity(listing: listing)
            }
            guard let connection = saved[id] else { return nil }
            let name = connection.name.isEmpty ? connection.host : connection.name
            return ConnectionEntity(id: id, name: name, host: "", databaseType: "")
        }
    }
}
