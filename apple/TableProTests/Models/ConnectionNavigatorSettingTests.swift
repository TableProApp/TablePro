//
//  ConnectionNavigatorSettingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ConnectionNavigatorSettingTests {
    private static func encoded(_ settings: GeneralSettings) throws -> [String: Any] {
        let data = try JSONEncoder().encode(settings)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func decoded(_ object: [String: Any]) throws -> GeneralSettings {
        try JSONDecoder().decode(GeneralSettings.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("The navigator starts off")
    func startsOff() {
        #expect(GeneralSettings.default.showsConnectionNavigator == false)
        #expect(GeneralSettings().showsConnectionNavigator == false)
    }

    @Test("Settings saved before the navigator existed decode with it off")
    func missingKeyDecodesOff() throws {
        let decoded = try Self.decoded(["startupBehavior": "showWelcome"])
        #expect(decoded.showsConnectionNavigator == false)
    }

    @Test("Turning the navigator on survives a round trip and leaves the strip setting alone")
    func roundTripsOn() throws {
        var object = try Self.encoded(.default)
        object["showsConnectionNavigator"] = true

        let decoded = try Self.decoded(object)

        #expect(decoded.showsConnectionNavigator)
        #expect(decoded.showWorkspaceRail)
    }
}
