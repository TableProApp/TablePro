import Foundation
@testable import TablePro
import TableProProcess
import Testing

struct SSHAddCommandTests {
    // The key path comes from the form or an imported IdentityFile.
    @Test("A key path that starts with a dash follows --, so ssh-add reads it as a file")
    func keyPathFollowsEndOfOptions() {
        let command = LibSSH2TunnelFactory.sshAddCommand(keyPath: "-dashkey")

        #expect(command.executable.path == "/usr/bin/ssh-add")
        #expect(command.arguments == ["--apple-use-keychain", "--", "-dashkey"])
    }

    @Test("ssh-add keeps the agent socket and drops what else the app inherited")
    func environmentKeepsOnlyTheAgentSocket() {
        let command = LibSSH2TunnelFactory.sshAddCommand(
            keyPath: "/Users/a/.ssh/id_ed25519",
            environment: ["SSH_AUTH_SOCK": "/tmp/agent.sock", "HOME": "/Users/a", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"]
        )

        #expect(command.environment == ["SSH_AUTH_SOCK": "/tmp/agent.sock", "HOME": "/Users/a"])
    }
}
