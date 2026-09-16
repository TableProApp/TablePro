//
//  AnalyticsHeartbeatPayloadTests.swift
//  TableProAnalyticsTests
//

import CryptoKit
import Foundation
import Testing

@testable import TableProAnalytics

@MainActor
@Suite("AnalyticsHeartbeatService payload encoding")
struct AnalyticsHeartbeatPayloadTests {
    private final class StubProvider: AnalyticsEnvironmentProvider {
        var machineId = "machine-1"
        var appVersion: String? = "1.0.0"
        var osVersion = "macOS 15.1.0"
        var architecture = "arm64"
        var platform = "macos"
        var locale = "en"
        var isAnalyticsEnabled = true
        var hasLicense = false
        var activeDatabaseTypes: [String] = []
        var activeConnectionCount = 0
        var hmacSecret: String?
        var connectionAttemptedAt: Date?
        var connectionSucceededAt: Date?
        var firstQueryExecutedAt: Date?
        var updateInstallMode: String?
        var updateCheckInterval: Int?
    }

    private func makeService(provider: StubProvider) -> AnalyticsHeartbeatService {
        AnalyticsHeartbeatService(
            provider: provider,
            heartbeatInterval: 60,
            initialDelay: 60,
            cooldownInterval: 0
        )
    }

    private func makePayload(provider: StubProvider) -> AnalyticsPayload {
        AnalyticsPayload(
            machineId: provider.machineId,
            platform: provider.platform,
            appVersion: provider.appVersion,
            osVersion: provider.osVersion,
            architecture: provider.architecture,
            locale: provider.locale,
            databaseTypes: provider.activeDatabaseTypes.isEmpty ? nil : provider.activeDatabaseTypes,
            connectionCount: provider.activeConnectionCount,
            hasLicense: provider.hasLicense,
            connectionAttemptedAt: provider.connectionAttemptedAt,
            connectionSucceededAt: provider.connectionSucceededAt,
            firstQueryExecutedAt: provider.firstQueryExecutedAt,
            updateInstallMode: provider.updateInstallMode,
            updateCheckInterval: provider.updateCheckInterval
        )
    }

    @Test("Encodes new timestamp fields as ISO 8601 strings in snake_case keys")
    func encodesTimestampsIso8601() throws {
        let provider = StubProvider()
        let attempted = Date(timeIntervalSince1970: 1_700_000_000)
        let succeeded = Date(timeIntervalSince1970: 1_700_000_300)
        let queried = Date(timeIntervalSince1970: 1_700_001_000)
        provider.connectionAttemptedAt = attempted
        provider.connectionSucceededAt = succeeded
        provider.firstQueryExecutedAt = queried

        let service = makeService(provider: provider)
        let body = try service.makeEncodedBodyForTesting(payload: makePayload(provider: provider))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["connection_attempted_at"] as? String == ISO8601DateFormatter().string(from: attempted))
        #expect(json["connection_succeeded_at"] as? String == ISO8601DateFormatter().string(from: succeeded))
        #expect(json["first_query_executed_at"] as? String == ISO8601DateFormatter().string(from: queried))
    }

    @Test("Omits timestamp fields when provider returns nil")
    func omitsNilTimestampFields() throws {
        let provider = StubProvider()
        let service = makeService(provider: provider)
        let body = try service.makeEncodedBodyForTesting(payload: makePayload(provider: provider))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["connection_attempted_at"] == nil)
        #expect(json["connection_succeeded_at"] == nil)
        #expect(json["first_query_executed_at"] == nil)
    }

    @Test("Includes existing payload fields with snake_case keys")
    func encodesExistingFields() throws {
        let provider = StubProvider()
        provider.activeDatabaseTypes = ["mysql", "postgresql"]
        provider.activeConnectionCount = 2
        provider.hasLicense = true

        let service = makeService(provider: provider)
        let body = try service.makeEncodedBodyForTesting(payload: makePayload(provider: provider))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["machine_id"] as? String == "machine-1")
        #expect(json["app_version"] as? String == "1.0.0")
        #expect(json["os_version"] as? String == "macOS 15.1.0")
        #expect(json["connection_count"] as? Int == 2)
        #expect(json["has_license"] as? Bool == true)
    }

    @Test("HMAC signature covers the encoded body including new fields")
    func hmacCoversNewFields() throws {
        let provider = StubProvider()
        provider.hmacSecret = "test-secret"

        let service = makeService(provider: provider)
        let basePayload = makePayload(provider: provider)
        let baseBody = try service.makeEncodedBodyForTesting(payload: basePayload)

        provider.firstQueryExecutedAt = Date(timeIntervalSince1970: 1_700_001_000)
        let withTimestampPayload = makePayload(provider: provider)
        let withTimestampBody = try service.makeEncodedBodyForTesting(payload: withTimestampPayload)

        let key = SymmetricKey(data: Data("test-secret".utf8))
        let baseSig = HMAC<SHA256>.authenticationCode(for: baseBody, using: key)
            .map { String(format: "%02x", $0) }
            .joined()
        let withSig = HMAC<SHA256>.authenticationCode(for: withTimestampBody, using: key)
            .map { String(format: "%02x", $0) }
            .joined()

        #expect(baseSig != withSig, "Signature must change when payload contents change")
        #expect(baseBody != withTimestampBody, "Body must differ when a new timestamp is included")
    }
}

@MainActor
@Suite("AnalyticsHeartbeatService update fields")
struct AnalyticsUpdateFieldTests {
    private final class StubProvider: AnalyticsEnvironmentProvider {
        var machineId = "machine-1"
        var appVersion: String? = "1.0.0"
        var osVersion = "macOS 15.1.0"
        var architecture = "arm64"
        var platform = "macos"
        var locale = "en"
        var isAnalyticsEnabled = true
        var hasLicense = false
        var activeDatabaseTypes: [String] = []
        var activeConnectionCount = 0
        var hmacSecret: String?
    }

    private func encoded(mode: String?, interval: Int?) throws -> [String: Any] {
        let payload = AnalyticsPayload(
            machineId: "machine-1",
            platform: "macos",
            appVersion: "1.0.0",
            osVersion: "macOS 15.1.0",
            architecture: "arm64",
            locale: "en",
            databaseTypes: nil,
            connectionCount: 0,
            hasLicense: false,
            updateInstallMode: mode,
            updateCheckInterval: interval
        )
        let service = AnalyticsHeartbeatService(
            provider: StubProvider(),
            heartbeatInterval: 60,
            initialDelay: 60,
            cooldownInterval: 0
        )
        let data = try service.makeEncodedBodyForTesting(payload: payload)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    /// The whole point of these two fields is measuring whether a default that was flipped for
    /// every existing install was accepted, so the wire keys have to match what the backend reads.
    @Test("Encodes the update fields in snake_case")
    func encodesUpdateFields() throws {
        let body = try encoded(mode: "automatic", interval: 86_400)

        #expect(body["update_install_mode"] as? String == "automatic")
        #expect(body["update_check_interval"] as? Int == 86_400)
    }

    @Test("Omits both when the platform has no updater")
    func omitsWhenAbsent() throws {
        let body = try encoded(mode: nil, interval: nil)

        #expect(body["update_install_mode"] == nil)
        #expect(body["update_check_interval"] == nil)
    }

    /// Checks off means there is no interval to report, and the mode still says so.
    @Test("Reports the mode with no interval when checks are off")
    func reportsModeWithoutInterval() throws {
        let body = try encoded(mode: "off", interval: nil)

        #expect(body["update_install_mode"] as? String == "off")
        #expect(body["update_check_interval"] == nil)
    }

    /// A provider that implements neither gets nil from the protocol default, which is what keeps
    /// the iOS provider compiling untouched.
    @Test("A provider that implements neither reports neither")
    func defaultsToNil() {
        let provider = StubProvider()

        #expect(provider.updateInstallMode == nil)
        #expect(provider.updateCheckInterval == nil)
    }
}
