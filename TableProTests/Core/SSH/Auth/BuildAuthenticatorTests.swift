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
        identityFiles: [String] = [],
        identitiesOnly: Bool = false,
        agentSocketOrigin: AgentSocketOrigin = .environment
    ) -> ResolvedSSHTarget {
        ResolvedSSHTarget(
            originalHost: host,
            host: host,
            port: port,
            username: username,
            identityFiles: identityFiles,
            agentSocketPath: "",
            agentSocketOrigin: agentSocketOrigin,
            identitiesOnly: identitiesOnly,
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

    @Test("SSH agent auth is the agent and a second factor, nothing else (#2583)")
    func sshAgentChainHoldsNoKeyFile() throws {
        let authenticator = try LibSSH2TunnelFactory.buildAuthenticator(
            config: config(authMethod: .sshAgent, totpMode: .none),
            resolved: resolved(),
            credentials: credentials()
        )
        let composite = try #require(authenticator as? CompositeAuthenticator)

        #expect(composite.authenticators.count == 2)
        #expect(composite.authenticators.first is AgentAuthenticator)
        #expect(composite.authenticators.last is KeyboardInteractiveAuthenticator)
    }

    /// An identity file reaches the agent as the key to select, never as a key file to read: the
    /// agent is the credential, and reading one the user never chose put TablePro's own passphrase
    /// prompt over an agent that had simply not been reached (#2583). Selecting with it is what
    /// keeps an agent holding more keys than the server allows tries usable (#2601), so the chain
    /// stays two long while the files themselves are handed to the agent step.
    @Test("SSH agent auth selects with an identity file rather than reading one (#2583, #2601)")
    func sshAgentSelectsWithResolvedIdentityFiles() throws {
        let identityFiles = ["/home/alice/.ssh/id_ed25519", "/home/alice/.ssh/id_rsa"]
        let authenticator = try LibSSH2TunnelFactory.buildAuthenticator(
            config: config(authMethod: .sshAgent, totpMode: .none),
            resolved: resolved(identityFiles: identityFiles, identitiesOnly: true),
            credentials: credentials()
        )
        let composite = try #require(authenticator as? CompositeAuthenticator)

        #expect(composite.authenticators.count == 2)
        #expect(composite.authenticators.last is KeyboardInteractiveAuthenticator)

        let agent = try #require(composite.authenticators.first as? AgentAuthenticator)
        #expect(agent.identityFiles == identityFiles)
        #expect(agent.identitiesOnly)
    }

    @Test("Private key auth still tries every resolved identity file")
    func privateKeyKeepsEveryIdentityFile() throws {
        let authenticator = try LibSSH2TunnelFactory.buildAuthenticator(
            config: config(authMethod: .privateKey, totpMode: .none),
            resolved: resolved(identityFiles: ["/home/alice/.ssh/id_ed25519", "/home/alice/.ssh/id_rsa"]),
            credentials: credentials()
        )
        let composite = try #require(authenticator as? CompositeAuthenticator)

        #expect(composite.authenticators.count == 3)
        #expect(composite.authenticators.last is KeyboardInteractiveAuthenticator)
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
