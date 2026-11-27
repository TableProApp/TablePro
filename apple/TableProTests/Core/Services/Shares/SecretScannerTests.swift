//
//  SecretScannerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct SecretScannerTests {
    private func kinds(_ sql: String) -> [SecretKind] {
        SecretScanner.scanSQL(sql).map(\.kind)
    }

    // Built at run time so no literal in this file reads as a live credential to a scanner.
    private static let fakeGitHub = "ghp_" + String(repeating: "a1B2", count: 9)
    private static let fakeGoogle = "AIza" + String(repeating: "x", count: 35)
    private static let fakeAWS = "AKIA" + String(repeating: "Z", count: 16)

    @Test("Each provider pattern is recognised", arguments: [
        (SecretScannerTests.fakeAWS, SecretKind.awsAccessKey),
        ("-----BEGIN RSA PRIVATE KEY-----", .privateKey),
        ("-----BEGIN PRIVATE KEY-----", .privateKey),
        ("-----BEGIN ENCRYPTED PRIVATE KEY-----", .privateKey),
        ("-----BEGIN PKCS8 PRIVATE KEY-----", .privateKey),
        ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl", .jsonWebToken),
        (SecretScannerTests.fakeGitHub, .gitHubToken),
        ("xoxb-1234", .slackToken),
        ("sk_live_abc", .stripeSecretKey),
        (SecretScannerTests.fakeGoogle, .googleAPIKey),
        ("postgres://admin:hunter2@db.internal/app", .urlCredentials)
    ])
    func providerPatterns(token: String, kind: SecretKind) {
        #expect(kinds("SELECT '\(token)'").contains(kind))
    }

    @Test("A quoted value assigned to a password-like name, bare or quoted in any style, is flagged", arguments: [
        "UPDATE users SET password = 'hunter2'",
        "SELECT * FROM t WHERE api_key='abc'",
        "SELECT * FROM t WHERE user_secret := 'abc'",
        "SELECT '{\"token\": \"abc\"}'",
        "SELECT * FROM t WHERE \"passwd\" = 'abc'",
        "SELECT * FROM t WHERE 'password' = 'abc'",
        "SET [db_passwd] = 'x'",
        "WHERE `Api_Key`='x'",
        "INSERT INTO t VALUES (secret => 'x')",
        "SET @pwd := 'x'"
    ])
    func passwordLiterals(sql: String) {
        #expect(kinds(sql).contains(.passwordLiteral))
    }

    @Test("Ordinary SQL raises nothing", arguments: [
        "SELECT id, name FROM users WHERE id = 1",
        "SELECT password_hash IS NULL FROM users",
        "UPDATE users SET password = ''",
        "UPDATE users SET password = \"\"",
        "SELECT 'https://example.com/path' AS link",
        "SELECT token_count FROM usage WHERE token_count > 10",
        "SELECT 'password' AS label",
        "SELECT * FROM users WHERE password = $1",
        "SELECT * FROM users WHERE token = :token",
        "SELECT '-----BEGIN PUBLIC KEY-----'"
    ])
    func ordinarySQL(sql: String) {
        #expect(SecretScanner.scanSQL(sql).isEmpty)
    }

    @Test("Hits carry the line they start on, counting CRLF as one break")
    func linesAreOneBased() {
        let sql = "SELECT 1;\r\nSELECT 2;\n-- \(Self.fakeAWS)\nSELECT 'sk_live_x'"
        #expect(SecretScanner.scanSQL(sql) == [
            SecretHit(kind: .awsAccessKey, line: 3),
            SecretHit(kind: .stripeSecretKey, line: 4)
        ])
    }

    @Test("A value that runs over lines is reported on the line its name starts")
    func multiLineValue() {
        #expect(SecretScanner.scanSQL("SELECT 1;\nUPDATE users SET password =\r\n'a\nb'") == [SecretHit(kind: .passwordLiteral, line: 2)])
    }

    @Test("Two hits of a kind on two lines are both reported, each on its own line")
    func twoHitsOnTwoLines() {
        #expect(SecretScanner.scanSQL("password='a'\npassword='b'") == [
            SecretHit(kind: .passwordLiteral, line: 1),
            SecretHit(kind: .passwordLiteral, line: 2)
        ])
        #expect(SecretScanner.scanSQL("-- postgres://app:pw@db1/x\r\n-- mysql://root:pw@db2/y") == [
            SecretHit(kind: .urlCredentials, line: 1),
            SecretHit(kind: .urlCredentials, line: 2)
        ])
        #expect(SecretScanner.scanSQL("-- postgres://app:pw@db1/x mysql://root:pw@db2/y") == [SecretHit(kind: .urlCredentials, line: 1)])
    }

    @Test("A kind found twice on one line is reported once")
    func oneHitPerKindAndLine() {
        #expect(SecretScanner.scanSQL("SELECT 'sk_live_a', 'sk_live_b'") == [SecretHit(kind: .stripeSecretKey, line: 1)])
    }

    @Test("A long run with no secret in it scans quickly")
    func longRunsStayLinear() {
        let run = String(repeating: "a", count: 200_000)
        let hex = String(repeating: "0a1b2c3d", count: 25_000)
        let started = ContinuousClock.now
        #expect(SecretScanner.scanSQL("SELECT '\(run)://\(run)'").isEmpty)
        #expect(SecretScanner.scanSQL("INSERT INTO t VALUES (X'\(hex)', '\(run) = 1')").isEmpty)
        #expect(SecretScanner.scanSQL("SELECT \(run)password\(run) FROM t").isEmpty)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    // DETECTOR-FIXTURES.md, Secret scan, SQL (core/crates/core/src/masking/detect/fixtures.rs).
    static let fixtureRows: [(String, [String])] = [
        ("-- \(SensitiveDataDetectorTests.fakeAWS)", ["awsAccessKey:1"]),
        ("-----BEGIN RSA PRIVATE KEY-----", ["privateKey:1"]),
        ("-----BEGIN PRIVATE KEY-----", ["privateKey:1"]),
        ("-----BEGIN OPENSSH PRIVATE KEY-----", ["privateKey:1"]),
        ("-----BEGIN EC2 PRIVATE KEY-----", ["privateKey:1"]),
        ("-----BEGIN ENCRYPTED  PRIVATE KEY-----", []),
        ("-----BEGIN rsa PRIVATE KEY-----", []),
        ("-----BEGIN PUBLIC KEY-----", []),
        ("-- \(SensitiveDataDetectorTests.jwt)", ["jsonWebToken:1"]),
        ("-- \(SensitiveDataDetectorTests.fakeGitHub)", ["gitHubToken:1"]),
        ("-- xoxb-123", ["slackToken:1"]),
        ("-- sk_live_abc", ["stripeSecretKey:1"]),
        ("-- \(SensitiveDataDetectorTests.fakeGoogle)", ["googleAPIKey:1"]),
        ("-- postgres://app:hunter2@db.internal/shop", ["urlCredentials:1"]),
        ("-- https://a@b:c@d", []),
        ("https://tablepro.app/docs", []),
        ("WHERE u.password = 'hunter2'", ["passwordLiteral:1"]),
        ("SELECT '{\"token\": \"abc\"}'::jsonb", ["passwordLiteral:1"]),
        ("WHERE \"password\" = 'x'", ["passwordLiteral:1"]),
        ("WHERE 'password' = \"x\"", ["passwordLiteral:1"]),
        ("SET `password` := 'x'", ["passwordLiteral:1"]),
        ("VALUES ([db_passwd] => 'x')", ["passwordLiteral:1"]),
        ("WHERE Api_Key: 'x'", ["passwordLiteral:1"]),
        ("WHERE password = ''", []),
        ("WHERE password = \"\"", []),
        ("WHERE password = 'abc\" AND 1 = 1", []),
        ("WHERE password = 'a\nb'", ["passwordLiteral:1"]),
        ("SELECT password FROM users", []),
        ("WHERE token = :token", []),
        ("SELECT 'password' AS label", []),
        (
            "SELECT '\(SensitiveDataDetectorTests.fakeAWS)', '\(SensitiveDataDetectorTests.otherAWS)';\nSELECT 'sk_live_a'",
            ["awsAccessKey:1", "stripeSecretKey:2"]
        ),
        ("\r\rsk_live_x", ["stripeSecretKey:3"]),
        ("\r\n\r\nsk_live_x", ["stripeSecretKey:3"]),
        ("\n\rsk_live_x", ["stripeSecretKey:3"])
    ]

    @Test("Secret scan, fixture table", arguments: SecretScannerTests.fixtureRows)
    func fixtures(sql: String, hits: [String]) {
        #expect(SecretScanner.scanSQL(sql).map { "\($0.kind.rawValue):\($0.line)" } == hits)
    }

    @Test("Secret columns, fixture table: whole words only")
    func columnFixtures() {
        #expect(SecretScanner.scanColumns([
            "id", "user_password", "PasswordHash", "access_token", "apiKey", "API-KEY", "client_secret", "ssn", "customerSSN",
            "ssn_last4", "credit_card", "CardNumber", "class_name", "lesson", "id", "user_password"
        ]) == [
            "user_password", "PasswordHash", "access_token", "apiKey", "API-KEY", "client_secret", "ssn", "customerSSN",
            "ssn_last4", "credit_card", "CardNumber"
        ])
        #expect(SecretScanner.scanColumns(["passwords", "tokens", "passwd", "secrets", "api_key_id"]) == ["passwd", "api_key_id"])
    }

    @Test("Column names that read like secrets are named, each once, in order")
    func sensitiveColumns() {
        let names = [
            "id", "password_hash", "apiKey", "API-KEY", "reset_token", "ssn", "user_ssn", "userSSN",
            "credit_card", "CardNumber", "client_secret", "classname", "session", "password_hash"
        ]
        #expect(SecretScanner.scanColumns(names) == [
            "password_hash", "apiKey", "API-KEY", "reset_token", "ssn", "user_ssn", "userSSN",
            "credit_card", "CardNumber", "client_secret"
        ])
    }
}
