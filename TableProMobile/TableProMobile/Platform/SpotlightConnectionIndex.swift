import CoreSpotlight
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
}

nonisolated protocol ConnectionSearchIndexing: Sendable {
    func replaceConnections(with connections: [SearchableConnection]) async throws
}

nonisolated struct SpotlightConnectionIndex: ConnectionSearchIndexing {
    static let domainIdentifier = "com.TablePro.connections"

    func replaceConnections(with connections: [SearchableConnection]) async throws {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let index = CSSearchableIndex.default()
        try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier])
        guard !connections.isEmpty else { return }
        try await index.indexSearchableItems(connections.map(Self.searchableItem(for:)))
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
