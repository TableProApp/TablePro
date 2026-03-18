//
//  SSLModeStringTests.swift
//  TableProTests
//
//  Tests that plugin SSL config structs correctly parse SSLMode raw values.
//  Plugin types are bundle targets and cannot be imported directly, so we
//  duplicate the config parsing logic here as private test helpers.
//

import Foundation
import Testing
@testable import TablePro

// MARK: - Test Helpers (mirror plugin SSL config structs)

/// Mirror of MySQLSSLConfig.Mode from MariaDBPluginConnection.swift
private enum TestMySQLSSLMode: String {
    case disabled = "Disabled"
    case preferred = "Preferred"
    case required = "Required"
    case verifyCa = "Verify CA"
    case verifyIdentity = "Verify Identity"
}

/// Mirror of RedisSSLConfig init from RedisPluginConnection.swift
private struct TestRedisSSLConfig {
    var isEnabled: Bool

    init(additionalFields: [String: String]) {
        let sslMode = additionalFields["sslMode"] ?? "Disabled"
        self.isEnabled = sslMode != "Disabled"
    }
}

/// Mirror of PQSSLConfig from LibPQPluginConnection.swift
private struct TestPQSSLConfig {
    var mode: String = "Disabled"

    init() {}

    init(additionalFields: [String: String]) {
        self.mode = additionalFields["sslMode"] ?? "Disabled"
    }

    var libpqSslMode: String {
        switch mode {
        case "Disabled": return "disable"
        case "Preferred": return "prefer"
        case "Required": return "require"
        case "Verify CA": return "verify-ca"
        case "Verify Identity": return "verify-full"
        default: return "disable"
        }
    }
}

// MARK: - SSLMode Raw Values Match Plugin Expectations

@Suite("SSL Mode String Consistency")
struct SSLModeStringTests {
    @Test("SSLMode.disabled.rawValue matches plugin disabled check")
    func disabledRawValue() {
        #expect(SSLMode.disabled.rawValue == "Disabled")
    }

    @Test("SSLMode.required.rawValue matches plugin required check")
    func requiredRawValue() {
        #expect(SSLMode.required.rawValue == "Required")
    }

    @Test("SSLMode.verifyCa.rawValue matches plugin verify CA check")
    func verifyCaRawValue() {
        #expect(SSLMode.verifyCa.rawValue == "Verify CA")
    }

    @Test("SSLMode.verifyIdentity.rawValue matches plugin verify identity check")
    func verifyIdentityRawValue() {
        #expect(SSLMode.verifyIdentity.rawValue == "Verify Identity")
    }

    @Test("All SSLMode cases round-trip through MySQL Mode enum")
    func mysqlModeRoundTrip() {
        for sslMode in SSLMode.allCases {
            let parsed = TestMySQLSSLMode(rawValue: sslMode.rawValue)
            #expect(parsed != nil, "MySQLSSLMode failed to parse '\(sslMode.rawValue)'")
        }
    }

    @Test("MySQL Mode parses each SSLMode raw value to the correct case")
    func mysqlModeParsesCorrectCase() {
        #expect(TestMySQLSSLMode(rawValue: "Disabled") == .disabled)
        #expect(TestMySQLSSLMode(rawValue: "Preferred") == .preferred)
        #expect(TestMySQLSSLMode(rawValue: "Required") == .required)
        #expect(TestMySQLSSLMode(rawValue: "Verify CA") == .verifyCa)
        #expect(TestMySQLSSLMode(rawValue: "Verify Identity") == .verifyIdentity)
    }

    @Test("Redis SSL disabled when sslMode is Disabled")
    func redisSSLDisabled() {
        let config = TestRedisSSLConfig(additionalFields: ["sslMode": "Disabled"])
        #expect(!config.isEnabled)
    }

    @Test("Redis SSL enabled when sslMode is Required")
    func redisSSLEnabled() {
        let config = TestRedisSSLConfig(additionalFields: ["sslMode": "Required"])
        #expect(config.isEnabled)
    }

    @Test("Redis SSL defaults to disabled when sslMode key is absent")
    func redisSSLDefaultDisabled() {
        let config = TestRedisSSLConfig(additionalFields: [:])
        #expect(!config.isEnabled)
    }

    @Test("PostgreSQL maps all SSLMode raw values to correct libpq modes")
    func pqSSLModeMapping() {
        #expect(TestPQSSLConfig(additionalFields: ["sslMode": "Disabled"]).libpqSslMode == "disable")
        #expect(TestPQSSLConfig(additionalFields: ["sslMode": "Preferred"]).libpqSslMode == "prefer")
        #expect(TestPQSSLConfig(additionalFields: ["sslMode": "Required"]).libpqSslMode == "require")
        #expect(TestPQSSLConfig(additionalFields: ["sslMode": "Verify CA"]).libpqSslMode == "verify-ca")
        #expect(TestPQSSLConfig(additionalFields: ["sslMode": "Verify Identity"]).libpqSslMode == "verify-full")
    }

    @Test("PostgreSQL default init uses Disabled")
    func pqDefaultInit() {
        let config = TestPQSSLConfig()
        #expect(config.mode == "Disabled")
        #expect(config.libpqSslMode == "disable")
    }

    @Test("MongoDB SSL mode string comparisons use correct case")
    func mongoDBSSLModeStrings() {
        // These mirror the comparisons in MongoDBConnection.buildUri()
        let disabled = SSLMode.disabled.rawValue
        let verifyCa = SSLMode.verifyCa.rawValue
        let verifyIdentity = SSLMode.verifyIdentity.rawValue

        #expect(disabled == "Disabled")
        let sslEnabled = disabled != "Disabled" && !disabled.isEmpty
        #expect(!sslEnabled)

        let required = SSLMode.required.rawValue
        let sslEnabledRequired = required != "Disabled" && !required.isEmpty
        #expect(sslEnabledRequired)

        let verifiesCert = verifyCa == "Verify CA" || verifyIdentity == "Verify Identity"
        #expect(verifiesCert)
    }

    @Test("ClickHouse SSL mode string comparisons use correct case")
    func clickHouseSSLModeStrings() {
        // These mirror the comparisons in ClickHousePlugin.connect() / buildRequest()
        let disabled = SSLMode.disabled.rawValue
        let useTLS = disabled != "Disabled"
        #expect(!useTLS)

        let required = SSLMode.required.rawValue
        let skipVerification = required == "Required"
        #expect(skipVerification)
    }
}
