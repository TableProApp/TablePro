//
//  KeychainHostSecrets.swift
//  TablePro
//

import Foundation
import TableProFFI

// The core's secret store on the Mac. Only the account asks it for anything: the Mac keeps its connections' and AI
// providers' secrets in Swift until their slices move (core ADR 0010).
internal final class KeychainHostSecrets: HostSecrets, @unchecked Sendable {
    private let keychain: AccountKeychain

    init(keychain: AccountKeychain) {
        self.keychain = keychain
    }

    func loadItem(item: SecretItemTag) throws -> SecretString? {
        do {
            return try keychain.refreshToken(signInKey: try Self.signInKey(item))
        } catch let failure as AccountKeychain.Failure {
            throw Self.error(failure)
        }
    }

    func storeItem(item: SecretItemTag, secret: SecretString) throws {
        do {
            try keychain.storeRefreshToken(secret, signInKey: try Self.signInKey(item))
        } catch let failure as AccountKeychain.Failure {
            throw Self.error(failure)
        }
    }

    func deleteItem(item: SecretItemTag) throws {
        keychain.deleteRefreshToken(signInKey: try Self.signInKey(item))
    }

    func load(connectionId: String, kind: SecretKindTag) throws -> SecretString? {
        throw Self.notHere
    }

    func store(connectionId: String, kind: SecretKindTag, secret: SecretString, label: String) throws {
        throw Self.notHere
    }

    func relabel(connectionId: String, kind: SecretKindTag, label: String) throws {
        throw Self.notHere
    }

    func delete(connectionId: String, kind: SecretKindTag) throws {
        throw Self.notHere
    }

    func deleteConnection(connectionId: String) throws {
        throw Self.notHere
    }

    private static let notHere = HostSecretError.Unavailable(detail: "the Mac keeps this secret in Swift")

    // Nil is tablepro.app's item.
    private static func signInKey(_ item: SecretItemTag) throws -> String? {
        switch item {
        case .accountRefreshToken:
            return nil
        case .accountRefreshTokenFor(let signInKey):
            return signInKey
        case .mcpToken, .anthropicKey, .openAiKey, .openAiCompatibleKey:
            throw notHere
        }
    }

    private static func error(_ failure: AccountKeychain.Failure) -> HostSecretError {
        switch failure {
        case .locked: .Locked
        case .dismissed: .Dismissed
        case .failed(let detail): .Failed(detail: detail)
        }
    }
}
