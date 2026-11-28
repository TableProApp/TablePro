//
//  ConnectionSecretItem.swift
//  TablePro
//

import Foundation

// A connection's secrets by their Keychain item, and the ones a team envelope carries by core ADR 0056's name. A key
// file's passphrase never goes to the team: the team's copy names no key file of this device (core ADR 0079).
nonisolated enum ConnectionSecretItem: CaseIterable, Hashable, Sendable {
    case password
    case sshPassword
    case sshKeyPassphrase
    case totpSecret
    case sslClientKeyPassphrase

    var keyPrefix: String {
        switch self {
        case .password: "com.TablePro.password"
        case .sshPassword: "com.TablePro.sshpassword"
        case .sshKeyPassphrase: "com.TablePro.keypassphrase"
        case .totpSecret: "com.TablePro.totpsecret"
        case .sslClientKeyPassphrase: "com.TablePro.sslkeypassphrase"
        }
    }

    var teamEnvelopeKind: String? {
        switch self {
        case .password: "password"
        case .sshPassword: "ssh_password"
        case .totpSecret: "ssh_totp_secret"
        case .sshKeyPassphrase, .sslClientKeyPassphrase: nil
        }
    }

    static let teamEnvelopeItems = allCases.filter { $0.teamEnvelopeKind != nil }

    init?(teamEnvelopeKind: String) {
        guard let item = Self.teamEnvelopeItems.first(where: { $0.teamEnvelopeKind == teamEnvelopeKind }) else { return nil }
        self = item
    }
}
