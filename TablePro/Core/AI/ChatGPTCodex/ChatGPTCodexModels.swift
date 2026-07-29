//
//  ChatGPTCodexModels.swift
//  TablePro
//

import Foundation

struct ChatGPTCodexTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var accountID: String
    var email: String
    var planType: String?
    var expiresAt: Date

    static let expirySkew: TimeInterval = 60

    var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-Self.expirySkew)
    }
}

struct ChatGPTCodexClaims: Equatable, Sendable {
    let accountID: String
    let email: String
    let planType: String?
}

struct ChatGPTCodexTokenResponse: Sendable {
    let accessToken: String
    let refreshToken: String
    let idToken: String
    let expiresAt: Date
}

protocol ChatGPTCodexTokenRefreshing: Sendable {
    func refresh(refreshToken: String) async throws -> ChatGPTCodexTokenResponse
}
