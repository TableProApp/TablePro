import Foundation
@testable import TableProMobile
import Testing

@Suite("WidgetConnectionItem")
struct WidgetConnectionItemTests {
    @Test("encoded payload never contains database endpoint fields")
    func endpointFieldsAreNotPersisted() throws {
        let item = WidgetConnectionItem(id: UUID(), name: "Production", type: "PostgreSQL", sortOrder: 0, glyph: nil)
        let data = try JSONEncoder().encode(item)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains("host"))
        #expect(!json.contains("port"))
        #expect(json.contains("Production"))
        #expect(json.contains("PostgreSQL"))
    }

    @Test("decodes legacy payloads that still carry host and port")
    func decodesLegacyPayload() throws {
        let id = UUID()
        let legacy = """
        {"id":"\(id.uuidString)","name":"Old","type":"MySQL","host":"db.example.com","port":3306,"sortOrder":2}
        """
        let item = try JSONDecoder().decode(WidgetConnectionItem.self, from: Data(legacy.utf8))

        #expect(item.id == id)
        #expect(item.name == "Old")
        #expect(item.type == "MySQL")
        #expect(item.sortOrder == 2)
        #expect(item.glyph == nil)
    }

    @Test("The resolved glyph survives the app group file", arguments: [
        ConnectionGlyph(source: .asset, name: "postgresql-icon"),
        ConnectionGlyph(source: .symbol, name: "flame")
    ])
    func glyphRoundTrips(_ glyph: ConnectionGlyph) throws {
        let item = WidgetConnectionItem(id: UUID(), name: "Prod", type: "PostgreSQL", sortOrder: 0, glyph: glyph)

        let decoded = try JSONDecoder().decode(WidgetConnectionItem.self, from: JSONEncoder().encode(item))

        #expect(decoded == item)
        #expect(decoded.glyph == glyph)
    }
}
