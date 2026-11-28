//
//  ConnectionSecretItem.swift
//  TablePro
//

import Foundation

// The connection secrets a team envelope carries, by their Keychain item and by core ADR 0056's envelope table name.
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

    var envelopeKind: String {
        switch self {
        case .password: "password"
        case .sshPassword: "ssh_password"
        case .sshKeyPassphrase: "ssh_key_passphrase"
        case .totpSecret: "ssh_totp_secret"
        case .sslClientKeyPassphrase: "ssl_key_passphrase"
        }
    }

    init?(envelopeKind: String) {
        guard let item = Self.allCases.first(where: { $0.envelopeKind == envelopeKind }) else { return nil }
        self = item
    }
}
