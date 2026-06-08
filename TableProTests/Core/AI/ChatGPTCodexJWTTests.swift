//
//  ChatGPTCodexJWTTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ChatGPTCodexJWT")
struct ChatGPTCodexJWTTests {
    private func makeIDToken(
        accountID: String?,
        email: String?,
        plan: String?,
        exp: Double? = nil
    ) throws -> String {
        var auth: [String: Any] = [:]
        if let accountID { auth["chatgpt_account_id"] = accountID }
        if let plan { auth["chatgpt_plan_type"] = plan }
        var profile: [String: Any] = [:]
        if let email { profile["email"] = email }
        var payload: [String: Any] = [
            "https://api.openai.com/auth": auth,
            "https://api.openai.com/profile": profile
        ]
        if let exp { payload["exp"] = exp }
        let header = ChatGPTCodexBase64URL.encode(Data(#"{"alg":"none"}"#.utf8))
        let body = ChatGPTCodexBase64URL.encode(try JSONSerialization.data(withJSONObject: payload))
        return "\(header).\(body).signature"
    }

    @Test("Extracts account id, email, and plan from namespaced claims")
    func extractsClaims() throws {
        let token = try makeIDToken(accountID: "acct_42", email: "dev@example.com", plan: "plus")
        let claims = try ChatGPTCodexJWT.decodeClaims(from: token)
        #expect(claims.accountID == "acct_42")
        #expect(claims.email == "dev@example.com")
        #expect(claims.planType == "plus")
    }

    @Test("Missing account id throws")
    func missingAccountIDThrows() throws {
        let token = try makeIDToken(accountID: nil, email: "dev@example.com", plan: "plus")
        #expect(throws: ChatGPTCodexJWT.DecodeError.self) {
            _ = try ChatGPTCodexJWT.decodeClaims(from: token)
        }
    }

    @Test("Malformed token throws")
    func malformedThrows() {
        #expect(throws: ChatGPTCodexJWT.DecodeError.self) {
            _ = try ChatGPTCodexJWT.decodeClaims(from: "not-a-jwt")
        }
    }

    @Test("Reads expiry from the exp claim")
    func readsExpiry() throws {
        let token = try makeIDToken(accountID: "a", email: "e", plan: nil, exp: 2_000_000_000)
        let expiry = ChatGPTCodexJWT.expiration(from: token)
        #expect(expiry == Date(timeIntervalSince1970: 2_000_000_000))
    }
}
