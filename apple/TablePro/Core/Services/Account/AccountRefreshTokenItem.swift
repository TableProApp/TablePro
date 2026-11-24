//
//  AccountRefreshTokenItem.swift
//  TablePro
//

import Foundation

// The Keychain items the core keeps the account's refresh tokens in, device-only. tablepro.app's is the item builds
// before the core wrote, so an update stays signed in; a company server's carries the core's key for that server.
internal enum AccountRefreshTokenItem {
    static let production = "com.TablePro.account.refreshToken"

    static func key(signInKey: String?) -> String {
        guard let signInKey, !signInKey.isEmpty else { return production }
        return "\(production).\(signInKey)"
    }
}
