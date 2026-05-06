//
//  BuildAuthenticatorTests.swift
//  TableProTests
//
//  Regression tests for `LibSSH2TunnelFactory.buildAuthenticator`. The Password +
//  Keyboard-Interactive composite (the path used when an SSH server requires both a
//  machine password and a TOTP / Google Authenticator code) was passing `password: nil`
//  into the kbd-interactive fallback, so on servers that prompt `Password:` then
//  `Verification code:` the password challenge was answered with an empty string and
//  authentication failed. See TableProApp/TablePro#1005.
//

import Foundation
@testable import TablePro
import Testing

@Suite("LibSSH2TunnelFactory.buildAuthenticator")
struct BuildAuthenticatorTests {
    private func resolved(
        host: String = "ssh.example.com",
        username: String = "alice",
        port: Int = 22
    ) -> ResolvedSSHTarget {
        ResolvedSSHTarget(
            originalHost: host,
            host: host,
            port: port,
            username: username,
            identityFiles: [],
            agentSocketPath: "",
            identitiesOnly: false,
            useKeychain: false,
            addKeysToAgent: false,
            proxyJump: []
        )
    }

    private func passwordTOTPConfig() -> SSHConfiguration {
        var config = SSHConfiguration(
            enabled: true,
            host: "ssh.example.com",
            username: "alice",
            authMethod: .password
        )
        config.totpMode = .promptAtConnect
        return config
    }

    @Test("Password + TOTP returns a Composite authenticator")
    func passwordPlusTotpIsComposite() throws {
        let credentials = SSHTunnelCredentials(
            sshPassword: "hunter2",
            keyPassphrase: nil,
            totpSecret: nil,
            totpProvider: nil
        )
        let authenticator = try LibSSH2TunnelFactory.buildAuthenticator(
            config: passwordTOTPConfig(),
            resolved: resolved(),
            credentials: credentials
        )

        #expect(authenticator is CompositeAuthenticator)
    }

    @Test("Password + TOTP keyboard-interactive fallback receives the SSH password")
    func passwordPlusTotpFallbackHasPassword() throws {
        let credentials = SSHTunnelCredentials(
            sshPassword: "hunter2",
            keyPassphrase: nil,
            totpSecret: nil,
            totpProvider: nil
        )
        let authenticator = try LibSSH2TunnelFactory.buildAuthenticator(
            config: passwordTOTPConfig(),
            resolved: resolved(),
            credentials: credentials
        )
        let composite = try #require(authenticator as? CompositeAuthenticator)

        #expect(composite.authenticators.count == 2)
        #expect(composite.authenticators.first is PasswordAuthenticator)

        let kbdint = try #require(composite.authenticators.last as? KeyboardInteractiveAuthenticator)
        #expect(kbdint.password == "hunter2")
        #expect(kbdint.totpProvider != nil)
    }

    @Test("Password without TOTP still falls through to keyboard-interactive with the SSH password")
    func passwordWithoutTotpFallsThroughToKeyboardInteractive() throws {
        var config = SSHConfiguration(
            enabled: true,
            host: "ssh.example.com",
            username: "alice",
            authMethod: .password
        )
        config.totpMode = .none
        let credentials = SSHTunnelCredentials(
            sshPassword: "hunter2",
            keyPassphrase: nil,
            totpSecret: nil,
            totpProvider: nil
        )

        let authenticator = try LibSSH2TunnelFactory.buildAuthenticator(
            config: config,
            resolved: resolved(),
            credentials: credentials
        )
        let composite = try #require(authenticator as? CompositeAuthenticator)

        #expect(composite.authenticators.count == 2)
        #expect(composite.authenticators.first is PasswordAuthenticator)

        let kbdint = try #require(composite.authenticators.last as? KeyboardInteractiveAuthenticator)
        #expect(kbdint.password == "hunter2")
        #expect(kbdint.totpProvider == nil)
    }

    @Test("Keyboard-Interactive auth method passes the password through directly")
    func keyboardInteractivePassesPassword() throws {
        var config = SSHConfiguration(
            enabled: true,
            host: "ssh.example.com",
            username: "alice",
            authMethod: .keyboardInteractive
        )
        config.totpMode = .promptAtConnect
        let credentials = SSHTunnelCredentials(
            sshPassword: "hunter2",
            keyPassphrase: nil,
            totpSecret: nil,
            totpProvider: nil
        )

        let authenticator = try LibSSH2TunnelFactory.buildAuthenticator(
            config: config,
            resolved: resolved(),
            credentials: credentials
        )
        let kbdint = try #require(authenticator as? KeyboardInteractiveAuthenticator)
        #expect(kbdint.password == "hunter2")
        #expect(kbdint.totpProvider != nil)
    }
}
