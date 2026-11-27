//
//  SSHStoredSecretNeeds.swift
//  TablePro
//

import Foundation

import TableProSSHConfig
import TableProSSHTransport

// The stored SSH secrets a sign-in can use, so a connect reads only those Keychain items. The password signs in
// for Password and serves Keyboard Interactive; the passphrase unlocks a key file; the TOTP secret is used only
// when the code is generated. A jump host takes none of them.
struct SSHStoredSecretNeeds: Equatable {
    let password: Bool
    let keyPassphrase: Bool
    let totpSecret: Bool

    init(authMethod: SSHAuthMethod, totpMode: TOTPMode, passwordGiven: Bool) {
        switch authMethod {
        case .password, .keyboardInteractive:
            password = !passwordGiven
            keyPassphrase = false
        case .privateKey:
            password = false
            keyPassphrase = true
        case .sshAgent, .none:
            password = false
            keyPassphrase = false
        }
        totpSecret = totpMode == .autoGenerate
    }
}
