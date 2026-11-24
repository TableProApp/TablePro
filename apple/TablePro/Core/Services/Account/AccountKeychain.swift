//
//  AccountKeychain.swift
//  TablePro
//

import Foundation

// The account's refresh tokens for the core's HostSecrets, through the device-only Keychain and the same calls the
// Swift session made before, so an update reads the item it left.
internal struct AccountKeychain: Sendable {
    enum Failure: Error, Equatable {
        case locked
        case dismissed
        case failed(String)
    }

    let keychain: any KeychainStoring

    func refreshToken(signInKey: String?) throws(Failure) -> String? {
        switch keychain.readStringResult(forKey: AccountRefreshTokenItem.key(signInKey: signInKey)) {
        case .found(let token):
            return token.isEmpty ? nil : token
        case .notFound:
            return nil
        case .locked:
            throw .locked
        case .userCancelled:
            throw .dismissed
        case .authFailed:
            throw .failed("the Keychain refused the item")
        case .error(let status):
            throw .failed("Keychain error \(status)")
        }
    }

    func storeRefreshToken(_ token: String, signInKey: String?) throws(Failure) {
        guard keychain.writeString(token, forKey: AccountRefreshTokenItem.key(signInKey: signInKey)) else {
            throw .failed("the Keychain did not store the item")
        }
    }

    func deleteRefreshToken(signInKey: String?) {
        keychain.delete(forKey: AccountRefreshTokenItem.key(signInKey: signInKey))
    }
}
