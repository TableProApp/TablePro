//
//  ShareService.swift
//  TablePro
//

import Foundation

internal protocol ShareService: Sendable {
    func limits() async throws(ShareFailure) -> ShareLimits
    func create(_ draft: ShareDraft) async throws(ShareFailure) -> CreatedShare
    // The account's own live links, oldest first.
    func liveLinks() async throws(ShareFailure) -> [ShareLink]
    func revoke(id: String) async throws(ShareFailure)
    // The public read a tablepro://share link opens; needs no session.
    func fetchShared(token: String, password: String?) async throws(ShareFailure) -> SharedQuery
}

internal enum ShareToken {
    static let length = 43

    // 43 characters of base62, the only shape the server ever issues.
    static func isValid(_ token: String) -> Bool {
        token.utf8.count == length && token.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        }
    }
}
