//
//  RegistryClientURLTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("RegistryClient Configurable URL", .serialized)
@MainActor
struct RegistryClientURLTests {
    private let suiteName = "com.TablePro.tests.RegistryClientURLTests.\(UUID().uuidString)"
    private let customURLKey = RegistryClient.customRegistryURLKey

    private func makeClient(customURL: String) throws -> (RegistryClient, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(customURL, forKey: customURLKey)
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-url-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("registry-manifest.json")
        return (RegistryClient(userDefaults: defaults, manifestCacheURL: cacheURL), defaults)
    }

    @Test("customRegistryURLKey has expected value")
    func customURLKeyConstant() {
        #expect(RegistryClient.customRegistryURLKey == "com.TablePro.customRegistryURL")
    }

    @Test("setting a custom URL via UserDefaults is supported")
    func settingCustomURL() throws {
        let testURL = "https://custom.example.com/registry/manifest.json"
        let (client, defaults) = try makeClient(customURL: testURL)
        defer { defaults.removePersistentDomain(forName: suiteName) }

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
        let (client, defaults) = try makeClient(customURL: "not a valid url %%%")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(client.makeManifestRequest(forceRefresh: false).url != nil)
        #expect(client.session.configuration.timeoutIntervalForRequest == 15)
    }
}
