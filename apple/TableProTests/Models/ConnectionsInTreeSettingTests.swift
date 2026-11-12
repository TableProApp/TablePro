//
//  ConnectionsInTreeSettingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ConnectionsInTreeSettingTests {
    private static func encoded(_ settings: GeneralSettings) throws -> [String: Any] {
        let data = try JSONEncoder().encode(settings)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func decoded(_ object: [String: Any]) throws -> GeneralSettings {
        try JSONDecoder().decode(GeneralSettings.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("Saved connections stay out of the tree by default")
    func startsOff() {
        #expect(GeneralSettings.default.showsConnectionsInTree == false)
        #expect(GeneralSettings().showsConnectionsInTree == false)
    }

    @Test("Settings saved before the setting existed decode with it off")
    func missingKeyDecodesOff() throws {
        let decoded = try Self.decoded(["startupBehavior": "showWelcome"])
        #expect(decoded.showsConnectionsInTree == false)
    }

    @Test("Turning it on survives a round trip and leaves the connections column alone")
    func roundTripsOn() throws {
        var object = try Self.encoded(.default)
        object["showsConnectionsInTree"] = true

        let decoded = try Self.decoded(object)

        #expect(decoded.showsConnectionsInTree)
        #expect(!decoded.showsConnectionNavigator)
        #expect(decoded.showWorkspaceRail)
    }
}
