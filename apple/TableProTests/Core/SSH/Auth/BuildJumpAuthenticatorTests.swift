import Foundation
@testable import TableProSSHConfig
import TableProSSHTransport
import Testing

@testable import TablePro

// A bastion with `AuthenticationMethods publickey,keyboard-interactive` takes the key as one factor and
// asks for a code next, so every jump hop chain ends in keyboard-interactive, as the SSH host's does (#1920).
struct BuildJumpAuthenticatorTests {
    private func resolved(identityFiles: [String] = [], agentDisabled: Bool = false) -> ResolvedSSHTarget {
        ResolvedSSHTarget(
            originalHost: "bastion.example.com",
            host: "bastion.example.com",
            port: 22,
            username: "jump",
            identityFiles: identityFiles,
            agentSocketPath: "",
            agentSocketOrigin: .environment,
            agentDisabled: agentDisabled,
            identitiesOnly: false,
            useKeychain: false,
            addKeysToAgent: false,
            proxyJump: []
        )
    }

    private let credentials = SSHTunnelCredentials(
        sshPassword: "the SSH host's password",
        keyPassphrase: nil,
        totpSecret: "JBSWY3DPEHPK3PXP",
        keyboardInteractivePromptProvider: nil
    )

    private func hop(_ authMethod: SSHJumpAuthMethod, privateKeyPath: String = "") -> SSHJumpHost {
        SSHJumpHost(host: "bastion.example.com", username: "jump", authMethod: authMethod, privateKeyPath: privateKeyPath)
    }

    private func buildChain(_ jumpHost: SSHJumpHost, _ target: ResolvedSSHTarget) throws -> CompositeAuthenticator {
        let authenticator = try LibSSH2TunnelFactory.buildJumpAuthenticator(
            jumpHost: jumpHost,
            resolved: target,
            credentials: credentials
        )
        return try #require(authenticator as? CompositeAuthenticator)
    }

    // The hop prompts for its code: the SSH host's password and TOTP secret belong to another server.
    private func expectPromptedSecondFactor(_ chain: CompositeAuthenticator) throws {
        let secondFactor = try #require(chain.authenticators.last as? KeyboardInteractiveAuthenticator)
        #expect(secondFactor.password == nil)
        #expect(secondFactor.totpProvider == nil)
    }

    @Test("A private key hop asks for a second factor after its one key")
    func privateKeyHopEndsInKeyboardInteractive() throws {
        let chain = try buildChain(hop(.privateKey, privateKeyPath: "/home/alice/.ssh/bastion"), resolved(identityFiles: ["/home/alice/.ssh/bastion"]))

        #expect(chain.authenticators.count == 2)
        try expectPromptedSecondFactor(chain)
    }

    @Test("A private key hop tries every resolved key before the second factor")
    func privateKeyHopKeepsEveryKey() throws {
        let chain = try buildChain(hop(.privateKey), resolved(identityFiles: ["/home/alice/.ssh/id_ed25519", "/home/alice/.ssh/id_rsa"]))

        #expect(chain.authenticators.count == 3)
        try expectPromptedSecondFactor(chain)
    }

    @Test("An SSH agent hop asks for a second factor, and stops when the agent offered no key")
    func agentHopEndsInKeyboardInteractive() throws {
        let chain = try buildChain(hop(.sshAgent), resolved())

        #expect(chain.authenticators.count == 2)
        #expect(chain.authenticators.first is AgentAuthenticator)
        try expectPromptedSecondFactor(chain)
        #expect(chain.endsChainOn.contains(.agentUnavailable(.environment)))
    }

    @Test("An SSH agent hop with a key file falls back to the key, then asks for a second factor")
    func agentHopWithKeyFileEndsInKeyboardInteractive() throws {
        let chain = try buildChain(hop(.sshAgent, privateKeyPath: "/home/alice/.ssh/bastion"), resolved())

        #expect(chain.authenticators.count == 3)
        #expect(chain.authenticators.first is AgentAuthenticator)
        try expectPromptedSecondFactor(chain)
        #expect(chain.endsChainOn.isEmpty)
    }

    @Test("A hop whose agent the config turns off signs in with its key, then asks for a second factor")
    func agentDisabledHopEndsInKeyboardInteractive() throws {
        let chain = try buildChain(hop(.sshAgent, privateKeyPath: "/home/alice/.ssh/bastion"), resolved(agentDisabled: true))

        #expect(chain.authenticators.count == 2)
        try expectPromptedSecondFactor(chain)
    }
}
