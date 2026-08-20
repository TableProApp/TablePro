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
//  #1920 extends the same composition to key and agent auth: every method except None now
//  appends a keyboard-interactive authenticator so a `publickey,keyboard-interactive`
//  server (private key first factor, verification code second) can complete its second step.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("LibSSH2TunnelFactory.buildAuthenticator")
struct BuildAuthenticatorTests {
    private func resolved(
        host: String = "ssh.example.com",
        username: String = "alice",
        port: Int = 22,
        identityFiles: [String] = []
    ) -> ResolvedSSHTarget {
        ResolvedSSHTarget(
            originalHost: host,
            host: host,
            port: port,
            username: username,
            identityFiles: identityFiles,
            agentSocketPath: "",
            identitiesOnly: false,
            useKeychain: false,
            addKeysToAgent: false,
            proxyJump: []
        )
    }

    private func config(authMethod: SSHAuthMethod, totpMode: TOTPMode) -> SSHConfiguration {
        var config = SSHConfiguration(
            enabled: true,
            host: "ssh.example.com",
            username: "alice",
            authMethod: authMethod
        )
        config.totpMode = totpMode
        return config
    }

    private func credentials(
        sshPassword: String? = nil,
        totpSecret: String? = nil
    ) -> SSHTunnelCredentials {
        SSHTunnelCredentials(
            sshPassword: sshPassword,
            keyPassphrase: nil,
            totpSecret: totpSecret,
            keyboardInteractivePromptProvider: nil
        )
    }

    @Test("Password + prompt-at-connect returns a Composite authenticator")
    func passwordPlusPromptIsComposite() throws {
        let authenticator = try LibSSH2TunnelFactory.buildAuthenticator(
            config: config(authMethod: .password, totpMode: .promptAtConnect),
            resolved: resolved(),
            credentials: credentials(sshPassword: "hunter2")
        )

        #expect(authenticator is CompositeAuthenticator)
    }

    @Test("Password keyboard-interactive fallback receives the SSH password (#1005)")
    func passwordFallbackHasPassword() throws {
        let authenticator = try LibSSH2TunnelFactory.buildAuthenticator(
            config: config(authMethod: .password, totpMode: .promptAtConnect),
            resolved: resolved(),
            credentials: credentials(sshPassword: "hunter2")
        )
        let composite = try #require(authenticator as? CompositeAuthenticator)

        #expect(composite.authenticators.count == 2)
        #expect(composite.authenticators.first is PasswordAuthenticator)

        let kbdint = try #require(composite.authenticators.last as? KeyboardInteractiveAuthenticator)
        #expect(kbdint.password == "hunter2")
        #expect(kbdint.totpProvider == nil)
    }

    @Test("Password without TOTP still falls through to keyboard-interactive with the SSH password")
    func passwordWithoutTotpFallsThroughToKeyboardInteractive() throws {
        let authenticator = try LibSSH2TunnelFactory.buildAuthenticator(
            config: config(authMethod: .password, totpMode: .none),
            resolved: resolved(),
            credentials: credentials(sshPassword: "hunter2")
        )
        let composite = try #require(authenticator as? CompositeAuthenticator)

        #expect(composite.authenticators.count == 2)
        #expect(composite.authenticators.first is PasswordAuthenticator)

        let kbdint = try #require(composite.authenticators.last as? KeyboardInteractiveAuthenticator)
        #expect(kbdint.password == "hunter2")
        #expect(kbdint.totpProvider == nil)
    }

    @Test("Auto-generate TOTP builds a generating provider for the fallback")
    func autoGenerateProducesProvider() throws {
        let authenticator = try LibSSH2TunnelFactory.buildAuthenticator(
            config: config(authMethod: .password, totpMode: .autoGenerate),
            resolved: resolved(),
            credentials: credentials(sshPassword: "hunter2", totpSecret: "JBSWY3DPEHPK3PXP")
        )
        let composite = try #require(authenticator as? CompositeAuthenticator)
        let kbdint = try #require(composite.authenticators.last as? KeyboardInteractiveAuthenticator)

        #expect(kbdint.totpProvider != nil)
    }

    @Test("Private key auth appends a keyboard-interactive fallback even without TOTP (#1920)")
    func privateKeyAppendsKeyboardInteractive() throws {
        let authenticator = try LibSSH2TunnelFactory.buildAuthenticator(
            config: config(authMethod: .privateKey, totpMode: .none),
            resolved: resolved(identityFiles: ["/home/alice/.ssh/id_ed25519"]),
            credentials: credentials()
        )
        let composite = try #require(authenticator as? CompositeAuthenticator)

        let kbdint = try #require(composite.authenticators.last as? KeyboardInteractiveAuthenticator)
        #expect(kbdint.password == nil)
        #expect(kbdint.totpProvider == nil)
    }

    @Test("SSH agent auth appends a keyboard-interactive fallback even without TOTP (#1920)")
    func sshAgentAppendsKeyboardInteractive() throws {
        let authenticator = try LibSSH2TunnelFactory.buildAuthenticator(
            config: config(authMethod: .sshAgent, totpMode: .none),
            resolved: resolved(),
            credentials: credentials()
        )
        let composite = try #require(authenticator as? CompositeAuthenticator)

        #expect(composite.authenticators.first is AgentAuthenticator)
        let kbdint = try #require(composite.authenticators.last as? KeyboardInteractiveAuthenticator)
        #expect(kbdint.password == nil)
    }

    @Test("None auth method returns a NoneAuthenticator")
    func noneReturnsNoneAuthenticator() throws {
        let authenticator = try LibSSH2TunnelFactory.buildAuthenticator(
            config: config(authMethod: .none, totpMode: .none),
            resolved: resolved(),
            credentials: credentials()
        )

        #expect(authenticator is NoneAuthenticator)
    }

    @Test("Password auth method with no password throws before any libssh2 call")
    func passwordWithoutCredentialThrows() {
        #expect(throws: SSHTunnelError.authenticationFailed(reason: .password)) {
            try LibSSH2TunnelFactory.buildAuthenticator(
                config: config(authMethod: .password, totpMode: .none),
                resolved: resolved(),
                credentials: credentials()
            )
        }
    }

    @Test("Keyboard-Interactive auth method passes the password through directly")
    func keyboardInteractivePassesPassword() throws {
        let authenticator = try LibSSH2TunnelFactory.buildAuthenticator(
            config: config(authMethod: .keyboardInteractive, totpMode: .promptAtConnect),
            resolved: resolved(),
            credentials: credentials(sshPassword: "hunter2")
        )
        let kbdint = try #require(authenticator as? KeyboardInteractiveAuthenticator)
        #expect(kbdint.password == "hunter2")
        #expect(kbdint.totpProvider == nil)
    }
}
