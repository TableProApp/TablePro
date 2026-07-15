//
//  OAuthProviderService.swift
//  TablePro
//

import Foundation

enum OAuthAuthState: Sendable, Equatable {
    case signedOut
    case signingIn
    case signedIn(identity: String)

    var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }
}

enum OAuthFlowKind: Sendable, Equatable {
    case deviceCode
    case browserRedirect
}

@MainActor
protocol OAuthProviderService: AnyObject {
    var oauthState: OAuthAuthState { get }
}

enum OAuthProviderRegistry {
    @MainActor
    static func service(for type: AIProviderType) -> (any OAuthProviderService)? {
        switch type {
        case .copilot:
            return CopilotService.shared
        case .chatgptCodex:
            return ChatGPTCodexService.shared
        case .xai:
            return XAIService.shared
        default:
            return nil
        }
    }
}

extension CopilotService: OAuthProviderService {
    var oauthState: OAuthAuthState {
        switch authState {
        case .signedOut:
            return .signedOut
        case .signingIn:
            return .signingIn
        case .signedIn(let username):
            return .signedIn(identity: username)
        }
    }
}

extension ChatGPTCodexService: OAuthProviderService {
    var oauthState: OAuthAuthState {
        switch authState {
        case .signedOut:
            return .signedOut
        case .signingIn:
            return .signingIn
        case .signedIn(let email, _):
            return .signedIn(identity: email)
        }
    }
}

extension XAIService: OAuthProviderService {
    var oauthState: OAuthAuthState {
        switch authState {
        case .signedOut:
            return .signedOut
        case .signingIn:
            return .signingIn
        case .signedIn(let email):
            return .signedIn(identity: email)
        }
    }
}
