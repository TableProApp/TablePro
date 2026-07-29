//
//  ChatGPTCodex.swift
//  TablePro
//

import Foundation

enum ChatGPTCodex {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let issuer = "https://auth.openai.com"
    static let authorizeEndpoint = "\(issuer)/oauth/authorize"
    static let tokenEndpoint = "\(issuer)/oauth/token"
    static let revokeEndpoint = "\(issuer)/oauth/revoke"
    static let redirectPort: UInt16 = 1_455
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"
    static let backendBaseURL = "https://chatgpt.com/backend-api/codex"
    static let originator = "codex_cli_rs"
    static let userAgent = "codex_cli_rs/0.1.0"
    static let authClaimsNamespace = "https://api.openai.com/auth"
    static let profileClaimsNamespace = "https://api.openai.com/profile"
    static let curatedModelIDs = ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini"]
}

enum ChatGPTCodexBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}
