import AppIntents
import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite("ConnectionEntity")
struct ConnectionEntityTests {
    @Test("the Shortcuts subtitle names the type and the host with a comma")
    func subtitleJoinsTypeAndHost() throws {
        let entity = ConnectionEntity(id: UUID(), name: "Prod", host: "db.example.com", databaseType: "PostgreSQL")

        let subtitle = try #require(entity.displayRepresentation.subtitle)

        #expect(String(localized: subtitle) == "PostgreSQL, db.example.com")
    }

    @Test("A Cloudflare D1 connection's subtitle names its database, not the account id a Mac import keeps in Host")
    func cloudflareD1SubtitleNamesTheDatabase() throws {
        let connection = DatabaseConnection(
            name: "Edge",
            type: .cloudflareD1,
            host: "b5ad7a2e0123",
            port: 0,
            database: "shop"
        )

        let subtitle = try #require(ConnectionEntity(connection: connection).displayRepresentation.subtitle)

        #expect(String(localized: subtitle) == "Cloudflare D1, shop")
    }

    @Test("A file connection's subtitle names its file, as the connection list does")
    func fileSubtitleNamesTheFile() throws {
        let connection = DatabaseConnection(name: "Notes", type: .sqlite, host: "", port: 0, database: "/tmp/notes.db")

        let subtitle = try #require(ConnectionEntity(connection: connection).displayRepresentation.subtitle)

        #expect(String(localized: subtitle) == "SQLite, notes.db")
    }
}
