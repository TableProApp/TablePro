//
//  AISettingsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AISettings")
struct AISettingsTests {
    @Test("default has enabled true")
    func defaultEnabledIsTrue() {
        #expect(AISettings.default.enabled == true)
    }

    @Test("decoding without enabled key defaults to true")
    func decodingWithoutEnabledDefaultsToTrue() throws {
        let json = "{}"
        let data = json.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AISettings.self, from: data)
        #expect(settings.enabled == true)
    }

    @Test("decoding with enabled false sets it correctly")
    func decodingWithEnabledFalse() throws {
        let json = "{\"enabled\": false}"
        let data = json.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AISettings.self, from: data)
        #expect(settings.enabled == false)
    }
}
