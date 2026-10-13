import AppIntents
import Foundation
@testable import TableProMobile
import Testing

@Suite("ConnectionEntity")
struct ConnectionEntityTests {
    @Test("the Shortcuts subtitle names the type and the host with a comma")
    func subtitleJoinsTypeAndHost() throws {
        let entity = ConnectionEntity(id: UUID(), name: "Prod", host: "db.example.com", databaseType: "PostgreSQL")

        let subtitle = try #require(entity.displayRepresentation.subtitle)

        #expect(String(localized: subtitle) == "PostgreSQL, db.example.com")
    }
}
