//
//  RegistryClientURLTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@MainActor
struct RegistryClientURLTests {
    private let suite: EphemeralDefaults
    private let customURLKey = RegistryClient.customRegistryURLKey

    init() throws {
        suite = try EphemeralDefaults()
    }

    private func makeClient(customURL: String) -> RegistryClient {
        let defaults = suite.defaults
        defaults.set(customURL, forKey: customURLKey)
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-url-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("registry-manifest.json")
        return RegistryClient(userDefaults: defaults, manifestCacheURL: cacheURL)
    }

    @Test("customRegistryURLKey has expected value")
    func customURLKeyConstant() {
        #expect(RegistryClient.customRegistryURLKey == "com.TablePro.customRegistryURL")
    }

    @Test("setting a custom URL via UserDefaults is supported")
    func settingCustomURL() throws {
        let testURL = "https://custom.example.com/registry/manifest.json"
        let client = makeClient(customURL: testURL)

        #expect(client.isUsingCustomRegistry)
        let requested = client.makeManifestRequest(forceRefresh: false).url
        #expect(requested?.absoluteString == testURL)
        #expect(requested?.host() == "custom.example.com")
    }

    @Test("session has correct timeout configuration")
    func sessionConfiguration() {
        let config = RegistryClient.makeDefaultSession().configuration

        #expect(config.timeoutIntervalForRequest == 15)
    }

    @Test("invalid custom URL string does not crash")
    func invalidCustomURLFallsBackSafely() throws {
        let client = makeClient(customURL: "not a valid url %%%")

        #expect(client.makeManifestRequest(forceRefresh: false).url != nil)
        #expect(client.session.configuration.timeoutIntervalForRequest == 15)
    }
}
