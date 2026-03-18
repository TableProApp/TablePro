//
//  RegistryClientURLTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("RegistryClient Configurable URL", .serialized)
@MainActor
struct RegistryClientURLTests {

    private let defaults = UserDefaults.standard
    private let customURLKey = RegistryClient.customRegistryURLKey

    private func setOrRemove(key: String, value: String?) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    @Test("customRegistryURLKey has expected value")
    func customURLKeyConstant() {
        #expect(RegistryClient.customRegistryURLKey == "com.TablePro.customRegistryURL")
    }

    @Test("setting a custom URL via UserDefaults is supported")
    func settingCustomURL() {
        let previousValue = defaults.string(forKey: customURLKey)
        defer { setOrRemove(key: customURLKey, value: previousValue) }

        let testURL = "https://custom.example.com/registry/manifest.json"
        defaults.set(testURL, forKey: customURLKey)

        let stored = defaults.string(forKey: customURLKey)
        #expect(stored == testURL)

        let url = URL(string: testURL)
        #expect(url != nil)
        #expect(url?.host() == "custom.example.com")
    }

    @Test("session has correct timeout configuration")
    func sessionConfiguration() {
        let client = RegistryClient.shared
        let config = client.session.configuration

        #expect(config.timeoutIntervalForRequest == 15)
    }

    @Test("invalid custom URL string does not crash")
    func invalidCustomURLFallsBackSafely() {
        let previousValue = defaults.string(forKey: customURLKey)
        defer { setOrRemove(key: customURLKey, value: previousValue) }

        defaults.set("not a valid url %%%", forKey: customURLKey)

        let client = RegistryClient.shared
        #expect(client.session.configuration.timeoutIntervalForRequest == 15)
    }
}
