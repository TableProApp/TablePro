import CoreSpotlight
import CryptoKit
import Foundation
import TableProModels

nonisolated struct SearchableConnection: Equatable, Sendable {
    let id: UUID
    let title: String
    let summary: String

    init(id: UUID, title: String, summary: String) {
        self.id = id
        self.title = title
        self.summary = summary
    }

    init(connection: DatabaseConnection) {
        id = connection.id
        title = connection.name.isEmpty ? connection.host : connection.name
        summary = [connection.type.mobileDisplayName, ConnectionDetailFormatter.detail(for: connection)]
            .joined(separator: ", ")
    }

    // The build is part of it, so an update that changes how an item is written publishes again once.
    static func digest(of connections: [SearchableConnection], build: String) -> Data {
        var bytes = Data()
        for field in [build] + connections.flatMap({ [$0.id.uuidString, $0.title, $0.summary] }) {
            let utf8 = Data(field.utf8)
            withUnsafeBytes(of: UInt32(utf8.count).bigEndian) { bytes.append(contentsOf: $0) }
            bytes.append(utf8)
        }
        return Data(SHA256.hash(data: bytes))
    }
}

nonisolated protocol ConnectionSearchIndexing: Sendable {
    // The state the last finished replace stored, nil when none did.
    func storedState() async throws -> Data?
    func replaceConnections(with connections: [SearchableConnection], state: Data) async throws
}

nonisolated struct SpotlightConnectionIndex: ConnectionSearchIndexing {
    static let domainIdentifier = "com.TablePro.connections"
    // CoreSpotlight keeps a client state only for a named index; the default one supports no batch.
    static let indexName = "com.TablePro.connections"

    func storedState() async throws -> Data? {
        guard CSSearchableIndex.isIndexingAvailable() else { return nil }
        return try await Self.lastClientState(of: CSSearchableIndex(name: Self.indexName))
    }

    // Connections are all the app indexes. Deleting everything also resets the stored state, so an index a failed
    // replace emptied never passes for the projection it held before.
    func replaceConnections(with connections: [SearchableConnection], state: Data) async throws {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let index = CSSearchableIndex(name: Self.indexName)
        if (try? await Self.lastClientState(of: index)) == nil {
            // Builds before the named index wrote through the default one.
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier])
        }
        try await index.deleteAllSearchableItems()
        index.beginBatch()
        if !connections.isEmpty {
            // Journaled with the batch, so ending the batch is the one call awaited.
            index.indexSearchableItems(connections.map(Self.searchableItem(for:)), completionHandler: nil)
        }
        try await index.endBatch(withClientState: state)
    }

    // The async form returns a non-optional Data, though the index answers nil before any batch stored a state.
    private static func lastClientState(of index: CSSearchableIndex) async throws -> Data? {
        let state: Data? = try await withCheckedThrowingContinuation { continuation in
            index.fetchLastClientState { state, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: state)
                }
            }
        }
        guard let state, !state.isEmpty else { return nil }
        return state
    }

    static func searchableItem(for connection: SearchableConnection) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = connection.title
        attributes.contentDescription = connection.summary
        return CSSearchableItem(
            uniqueIdentifier: connection.id.uuidString,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
    }
}
