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

    @Test("A quoted value assigned to a password-like name is flagged", arguments: [
        "UPDATE users SET password = 'hunter2'",
        "SELECT * FROM t WHERE api_key='abc'",
        "SELECT * FROM t WHERE user_secret := 'abc'",
        "SELECT '{\"token\": \"abc\"}'",
        "SELECT * FROM t WHERE \"passwd\" = 'abc'"
    ])
    func passwordLiterals(sql: String) {
        #expect(kinds(sql).contains(.passwordLiteral))
    }

    @Test("Ordinary SQL raises nothing", arguments: [
        "SELECT id, name FROM users WHERE id = 1",
        "SELECT password_hash IS NULL FROM users",
        "UPDATE users SET password = ''",
        "SELECT 'https://example.com/path' AS link",
        "SELECT token_count FROM usage WHERE token_count > 10"
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

    @Test("A kind found twice on one line is reported once")
    func oneHitPerKindAndLine() {
        #expect(SecretScanner.scanSQL("SELECT 'sk_live_a', 'sk_live_b'") == [SecretHit(kind: .stripeSecretKey, line: 1)])
    }

    @Test("A long run with no secret in it scans quickly")
    func longRunsStayLinear() {
        let run = String(repeating: "a", count: 200_000)
        let started = ContinuousClock.now
        #expect(SecretScanner.scanSQL("SELECT '\(run)://\(run)'").isEmpty)
        #expect(ContinuousClock.now - started < .seconds(5))
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
