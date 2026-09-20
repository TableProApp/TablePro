//
//  SSHAuthMethodTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("SSHAuthMethod form contract")
struct SSHAuthMethodTests {
    @Test("None is the only method without two-factor authentication")
    func noneHidesTwoFactor() {
        #expect(SSHAuthMethod.none.supportsTwoFactorAuthentication == false)

        for method in SSHAuthMethod.allCases where method != .none {
            #expect(method.supportsTwoFactorAuthentication, "\(method.rawValue) should support two-factor")
        }
    }

    @Test("Every method decodes from its own raw value")
    func decodesOwnRawValue() {
        for method in SSHAuthMethod.allCases {
            #expect(SSHAuthMethod(carrying: method.rawValue) == method, "\(method.rawValue)")
        }
    }

    @Test("A method an iPhone wrote by case name is read as that method, not as Password")
    func decodesIOSSpelling() {
        #expect(SSHAuthMethod(carrying: "sshAgent") == .sshAgent)
        #expect(SSHAuthMethod(carrying: "privateKey") == .privateKey)
        #expect(SSHAuthMethod(carrying: "publicKey") == .privateKey)
        #expect(SSHAuthMethod(carrying: "keyboardInteractive") == .keyboardInteractive)
        #expect(SSHAuthMethod(carrying: "none") == .none)
        #expect(SSHAuthMethod(carrying: "password") == .password)
    }

    @Test("A method this app does not know falls back to Password")
    func unknownFallsBackToPassword() {
        #expect(SSHAuthMethod(carrying: "totp-only") == .password)
    }

    @Test("An agent tunnel an iPhone synced decodes as an agent tunnel")
    func decodesAgentTunnelFromIOSJSON() throws {
        let iosJSON = #"{"host":"prod-1","username":"deploy","authMethod":"sshAgent","jumpHosts":[]}"#
        let config = try JSONDecoder().decode(SSHConfiguration.self, from: Data(iosJSON.utf8))

        #expect(config.authMethod == .sshAgent)
        #expect(config.port == nil)
    }
}
