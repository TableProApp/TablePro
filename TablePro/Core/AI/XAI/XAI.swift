//
//  XAI.swift
//  TablePro
//

import Foundation

enum XAI {
    static let issuer = "https://auth.x.ai"
    static let authorizeEndpoint = "\(issuer)/oauth2/authorize"
    static let tokenEndpoint = "\(issuer)/oauth2/token"
    static let revokeEndpoint = "\(issuer)/oauth2/revoke"
    static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let scope = "openid profile email offline_access grok-cli:access api:access"

    static let redirectHost = "127.0.0.1"
    static let preferredRedirectPort: UInt16 = 56_121
    static let redirectPath = "/callback"

    static let apiBaseURL = "https://api.x.ai"

    static let cliProxyBaseURL = "https://cli-chat-proxy.grok.com/v1"
    static let cliClientVersion = "0.2.93"
    static let cliTokenAuthHeader = "X-XAI-Token-Auth"
    static let cliTokenAuthValue = "xai-grok-cli"
    static let cliClientVersionHeader = "x-grok-client-version"
    static let cliModelOverrideHeader = "x-grok-model-override"
    static let userAgent = "xai-grok-workspace/\(cliClientVersion)"

    static let apiCuratedModels: [CuratedModel] = [
        CuratedModel(
            id: "grok-4.5",
            displayName: "Grok 4.5",
            supportedEffortLevels: [.low, .medium, .high],
            defaultEffort: .medium
        ),
        CuratedModel(
            id: "grok-4.3",
            displayName: "Grok 4.3",
            supportedEffortLevels: [.low, .medium, .high],
            defaultEffort: .low
        )
    ]

    static let subscriptionModelIDs = ["grok-4.5", "grok-build", "grok-composer-2.5-fast"]

    static func redirectURI(port: UInt16) -> String {
        "http://\(redirectHost):\(port)\(redirectPath)"
    }
}

enum XAIBase64URL {
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

enum XAIIdentity {
    static func email(fromIDToken idToken: String) -> String {
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2,
              let data = XAIBase64URL.decode(String(segments[1])),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return payload["email"] as? String ?? ""
    }
}
