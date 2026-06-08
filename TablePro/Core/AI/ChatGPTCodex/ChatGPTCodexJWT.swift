//
//  ChatGPTCodexJWT.swift
//  TablePro
//

import Foundation

enum ChatGPTCodexJWT {
    enum DecodeError: Error, LocalizedError {
        case malformed
        case invalidPayload
        case missingAccountID

        var errorDescription: String? {
            switch self {
            case .malformed, .invalidPayload:
                return String(localized: "The ChatGPT sign-in token could not be read.")
            case .missingAccountID:
                return String(localized: "The ChatGPT account could not be identified.")
            }
        }
    }

    static func decodeClaims(from idToken: String) throws -> ChatGPTCodexClaims {
        let payload = try payloadObject(from: idToken)
        let authClaims = payload[ChatGPTCodex.authClaimsNamespace] as? [String: Any]
        let profileClaims = payload[ChatGPTCodex.profileClaimsNamespace] as? [String: Any]

        guard let accountID = authClaims?["chatgpt_account_id"] as? String, !accountID.isEmpty else {
            throw DecodeError.missingAccountID
        }
        let email = profileClaims?["email"] as? String
            ?? payload["email"] as? String
            ?? ""
        let planType = authClaims?["chatgpt_plan_type"] as? String
        return ChatGPTCodexClaims(accountID: accountID, email: email, planType: planType)
    }

    static func expiration(from token: String) -> Date? {
        guard let payload = try? payloadObject(from: token),
              let exp = payload["exp"] as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    private static func payloadObject(from token: String) throws -> [String: Any] {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { throw DecodeError.malformed }
        guard let data = ChatGPTCodexBase64URL.decode(String(segments[1])),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.invalidPayload
        }
        return payload
    }
}
