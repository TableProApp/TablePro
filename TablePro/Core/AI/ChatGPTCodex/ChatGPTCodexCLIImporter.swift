//
//  ChatGPTCodexCLIImporter.swift
//  TablePro
//

import Foundation

enum ChatGPTCodexCLIImporter {
    enum ImportError: Error, LocalizedError {
        case fileNotFound
        case invalidFormat

        var errorDescription: String? {
            switch self {
            case .fileNotFound:
                return String(localized: "No Codex CLI login found. Run codex login first, then try again.")
            case .invalidFormat:
                return String(localized: "The Codex CLI login could not be read.")
            }
        }
    }

    static func loadTokens(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> ChatGPTCodexTokens {
        let url = home.appending(path: ".codex/auth.json")
        guard let data = try? Data(contentsOf: url) else {
            throw ImportError.fileNotFound
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokensObject = json["tokens"] as? [String: Any],
              let accessToken = tokensObject["access_token"] as? String, !accessToken.isEmpty,
              let idToken = tokensObject["id_token"] as? String else {
            throw ImportError.invalidFormat
        }
        let refreshToken = tokensObject["refresh_token"] as? String ?? ""
        let claims = try? ChatGPTCodexJWT.decodeClaims(from: idToken)
        let accountID = tokensObject["account_id"] as? String ?? claims?.accountID ?? ""
        guard !accountID.isEmpty else {
            throw ImportError.invalidFormat
        }
        let expiresAt = ChatGPTCodexJWT.expiration(from: accessToken) ?? Date()
        return ChatGPTCodexTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountID: accountID,
            email: claims?.email ?? "",
            planType: claims?.planType,
            expiresAt: expiresAt
        )
    }
}
