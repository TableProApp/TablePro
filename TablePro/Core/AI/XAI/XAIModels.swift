//
//  XAIModels.swift
//  TablePro
//

import Foundation

struct XAITokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var email: String
    var expiresAt: Date

    static let expirySkew: TimeInterval = 60

    var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-Self.expirySkew)
    }
}

struct XAITokenResponse: Sendable {
    let accessToken: String
    let refreshToken: String
    let idToken: String
    let expiresAt: Date
}

protocol XAITokenRefreshing: Sendable {
    func refresh(refreshToken: String) async throws -> XAITokenResponse
}
