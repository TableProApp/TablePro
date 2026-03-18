//
//  SSHJumpHostTests.swift
//  TableProTests
//
//  Tests for SSHJumpHost model
//

import Foundation
@testable import TablePro
import Testing

@Suite("SSH Jump Host")
struct SSHJumpHostTests {
    @Test("proxyJumpString formats correctly")
    func testProxyJumpString() {
        let jumpHost = SSHJumpHost(host: "bastion.example.com", port: 2_222, username: "admin")
        #expect(jumpHost.proxyJumpString == "admin@bastion.example.com:2222")
    }

    @Test("proxyJumpString with default port")
    func testProxyJumpStringDefaultPort() {
        let jumpHost = SSHJumpHost(host: "bastion.example.com", username: "admin")
        #expect(jumpHost.proxyJumpString == "admin@bastion.example.com:22")
    }

    @Test("isValid with SSH Agent auth")
    func testIsValidWithSSHAgent() {
        let jumpHost = SSHJumpHost(host: "bastion.example.com", username: "admin", authMethod: .sshAgent)
        #expect(jumpHost.isValid == true)
    }

    @Test("isValid with Private Key auth and key path")
    func testIsValidWithPrivateKey() {
        let jumpHost = SSHJumpHost(
            host: "bastion.example.com", username: "admin",
            authMethod: .privateKey, privateKeyPath: "~/.ssh/id_rsa"
        )
        #expect(jumpHost.isValid == true)
    }

    @Test("isValid fails with Private Key auth and empty key path")
    func testIsInvalidWithPrivateKeyNoPath() {
        let jumpHost = SSHJumpHost(
            host: "bastion.example.com", username: "admin",
            authMethod: .privateKey, privateKeyPath: ""
        )
        #expect(jumpHost.isValid == false)
    }

    @Test("isValid fails with empty host")
    func testIsInvalidWithEmptyHost() {
        let jumpHost = SSHJumpHost(host: "", username: "admin")
        #expect(jumpHost.isValid == false)
    }

    @Test("isValid fails with empty username")
    func testIsInvalidWithEmptyUsername() {
        let jumpHost = SSHJumpHost(host: "bastion.example.com", username: "")
        #expect(jumpHost.isValid == false)
    }

    @Test("Codable round-trip preserves all fields")
    func testCodableRoundTrip() throws {
        let original = SSHJumpHost(
            host: "bastion.example.com", port: 2_222, username: "admin",
            authMethod: .privateKey, privateKeyPath: "~/.ssh/bastion_key"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SSHJumpHost.self, from: data)

        #expect(decoded.host == original.host)
        #expect(decoded.port == original.port)
        #expect(decoded.username == original.username)
        #expect(decoded.authMethod == original.authMethod)
        #expect(decoded.privateKeyPath == original.privateKeyPath)
    }

    @Test("Default values are correct")
    func testDefaultValues() {
        let jumpHost = SSHJumpHost()
        #expect(jumpHost.host == "")
        #expect(jumpHost.port == 22)
        #expect(jumpHost.username == "")
        #expect(jumpHost.authMethod == .sshAgent)
        #expect(jumpHost.privateKeyPath == "")
    }
}
