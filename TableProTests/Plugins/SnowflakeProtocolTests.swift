//
//  SnowflakeProtocolTests.swift
//  TableProTests
//
//  Tests for the Snowflake binding encoder, HTTP retry policy, re-auth code
//  classification, and heartbeat interval (compiled via symlinks from
//  SnowflakeDriverPlugin).
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Snowflake Binding Encoder")
struct SnowflakeBindingEncoderTests {
    @Test("Keys are 1-based string indices")
    func testKeysAreOneBased() {
        let bindings = SnowflakeBindingEncoder.encode([.text("a"), .text("b")])
        #expect(Set(bindings.keys) == ["1", "2"])
    }

    @Test("Text values bind as TEXT")
    func testTextBinding() {
        let bindings = SnowflakeBindingEncoder.encode([.text("O'Brien \\ path")])
        #expect(bindings["1"]?["type"] as? String == "TEXT")
        #expect(bindings["1"]?["value"] as? String == "O'Brien \\ path")
    }

    @Test("Bytes bind as BINARY hex")
    func testBinaryBinding() {
        let bindings = SnowflakeBindingEncoder.encode([.bytes(Data([0xAB, 0x01, 0xFF]))])
        #expect(bindings["1"]?["type"] as? String == "BINARY")
        #expect(bindings["1"]?["value"] as? String == "AB01FF")
    }

    @Test("Null binds as a typed null")
    func testNullBinding() {
        let bindings = SnowflakeBindingEncoder.encode([.null])
        #expect(bindings["1"]?["type"] as? String == "TEXT")
        #expect(bindings["1"]?["value"] is NSNull)
    }

    @Test("Encoded payload serializes as JSON")
    func testJSONSerializable() {
        let bindings = SnowflakeBindingEncoder.encode([.text("x"), .null, .bytes(Data([0x00]))])
        #expect(JSONSerialization.isValidJSONObject(bindings))
    }
}

@Suite("Snowflake Retry Policy")
struct SnowflakeRetryPolicyTests {
    @Test("Transient statuses are retried")
    func testTransientStatuses() {
        #expect(SnowflakeRetryPolicy.isTransient(statusCode: 500))
        #expect(SnowflakeRetryPolicy.isTransient(statusCode: 503))
        #expect(SnowflakeRetryPolicy.isTransient(statusCode: 429))
        #expect(SnowflakeRetryPolicy.isTransient(statusCode: 408))
    }

    @Test("Application errors are not retried")
    func testTerminalStatuses() {
        #expect(!SnowflakeRetryPolicy.isTransient(statusCode: 200))
        #expect(!SnowflakeRetryPolicy.isTransient(statusCode: 400))
        #expect(!SnowflakeRetryPolicy.isTransient(statusCode: 401))
        #expect(!SnowflakeRetryPolicy.isTransient(statusCode: 403))
    }

    @Test("Retried URL tags the attempt and keeps the request id")
    func testRetriedURLTagging() throws {
        let url = try #require(URL(string: "https://x.snowflakecomputing.com/queries/v1/query-request?requestId=abc&request_guid=old"))
        let retried = SnowflakeRetryPolicy.retriedURL(url, retryCount: 2, retryReason: 503, clientStartTime: 1_700_000)
        let components = try #require(URLComponents(url: retried, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["requestId"] == "abc")
        #expect(items["retryCount"] == "2")
        #expect(items["retryReason"] == "503")
        #expect(items["clientStartTime"] == "1700000")
        #expect(items["request_guid"] != "old")
    }

    @Test("Delay stays within the jitter bounds")
    func testDelayBounds() {
        var generator = SystemRandomNumberGenerator()
        var delay = SnowflakeRetryPolicy.baseDelay
        for _ in 0..<20 {
            delay = SnowflakeRetryPolicy.nextDelay(after: delay, using: &generator)
            #expect(delay >= SnowflakeRetryPolicy.baseDelay)
            #expect(delay <= SnowflakeRetryPolicy.maxDelay)
        }
    }
}

@Suite("Snowflake Re-Auth Classification")
struct SnowflakeReAuthTests {
    @Test("Session and token expiry codes trigger re-authentication")
    func testReauthCodes() {
        for code in ["390110", "390112", "390113", "390114", "390115", "390195"] {
            #expect(SnowflakeError.isReauthenticationCode(code))
        }
    }

    @Test("MFA and credential failures are terminal")
    func testTerminalCodes() {
        for code in ["394507", "394508", "394512", "390100", ""] {
            #expect(!SnowflakeError.isReauthenticationCode(code))
        }
    }

    @Test("A rejected MFA passcode is never replayed")
    func testRejectedPasscodeGuard() {
        let account = "guardtest-\(UUID().uuidString)"
        #expect(!SnowflakeMFATokenStore.isPasscodeRejected("123456", account: account, user: "U"))
        SnowflakeMFATokenStore.markPasscodeRejected("123456", account: account, user: "U")
        #expect(SnowflakeMFATokenStore.isPasscodeRejected("123456", account: account, user: "U"))
        #expect(!SnowflakeMFATokenStore.isPasscodeRejected("654321", account: account, user: "U"))
        #expect(!SnowflakeMFATokenStore.isPasscodeRejected("", account: account, user: "U"))
    }

    @Test("Inaccessible-object codes map to empty listings")
    func testInaccessibleObjectCodes() {
        #expect(SnowflakeError.isInaccessibleObjectCode("002043"))
        #expect(SnowflakeError.isInaccessibleObjectCode("2043"))
        #expect(SnowflakeError.queryFailed(code: "002043", message: "x").indicatesInaccessibleObject)
        #expect(!SnowflakeError.queryFailed(code: "390112", message: "x").indicatesInaccessibleObject)
        #expect(!SnowflakeError.authFailed("x").indicatesInaccessibleObject)
    }
}

@Suite("Plugin Session Context")
struct PluginSessionContextTests {
    @Test("Round-trips through Codable")
    func testCodableRoundTrip() throws {
        let context = PluginSessionContext(
            id: "warehouse",
            label: "Warehouse",
            iconName: "building.columns",
            currentValue: "COMPUTE_WH",
            availableValues: ["COMPUTE_WH", "LOAD_WH"]
        )
        let data = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(PluginSessionContext.self, from: data)
        #expect(decoded.id == context.id)
        #expect(decoded.currentValue == "COMPUTE_WH")
        #expect(decoded.availableValues == ["COMPUTE_WH", "LOAD_WH"])
    }
}

@Suite("Snowflake Heartbeat Interval")
struct SnowflakeHeartbeatIntervalTests {
    @Test("Interval is a quarter of master validity, clamped to 15 to 60 minutes")
    func testIntervalClamping() {
        #expect(SnowflakeHeartbeat.interval(masterValiditySeconds: 14_400) == 3_600)
        #expect(SnowflakeHeartbeat.interval(masterValiditySeconds: 7_200) == 1_800)
        #expect(SnowflakeHeartbeat.interval(masterValiditySeconds: 600) == 900)
        #expect(SnowflakeHeartbeat.interval(masterValiditySeconds: 100_000) == 3_600)
    }
}
