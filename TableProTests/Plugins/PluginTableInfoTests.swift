import Foundation
import TableProPluginKit
import Testing

@Suite("PluginTableInfo")
struct PluginTableInfoTests {
    @Test("Init without comment leaves it nil")
    func initWithoutComment() {
        let info = PluginTableInfo(name: "users", type: "TABLE")
        #expect(info.comment == nil)
    }

    @Test("Init with comment stores it")
    func initWithComment() {
        let info = PluginTableInfo(name: "users", type: "TABLE", comment: "Account records")
        #expect(info.comment == "Account records")
    }

    @Test("comment round-trips through JSON encoding")
    func commentRoundTrip() throws {
        let original = PluginTableInfo(name: "orders", type: "TABLE", comment: "Customer orders")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginTableInfo.self, from: data)
        #expect(decoded.comment == "Customer orders")
    }

    @Test("decoding a payload without comment keeps it nil for forward compatibility")
    func legacyPayloadDecodesToNilComment() throws {
        let legacyJson = """
        {
            "name": "users",
            "type": "TABLE"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PluginTableInfo.self, from: legacyJson)
        #expect(decoded.comment == nil)
        #expect(decoded.name == "users")
    }
}
