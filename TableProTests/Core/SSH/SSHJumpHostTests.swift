//
//  SSHJumpHostTests.swift
//  TableProTests
//
//  Tests for SSHJumpHost model
//

import Foundation
import TableProPluginKit
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

    @Test("isValid allows empty username (filled by runtime resolver)")
    func testValidWithEmptyUsername() {
        let jumpHost = SSHJumpHost(host: "bastion.example.com", username: "")
        #expect(jumpHost.isValid == true)
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
        #expect(jumpHost.port == nil)
        #expect(jumpHost.username == "")
        #expect(jumpHost.authMethod == .sshAgent)
        #expect(jumpHost.privateKeyPath == "")
    }

    @Test("A hop a shipped iOS build wrote without credentials decodes instead of throwing")
    func testDecodesHopWithoutCredentials() throws {
        let json = """
        [{"id":"6E0B1B3C-7E4C-4C3E-9B1E-4C8D2A1F0001","host":"bastion.example.com",
          "port":2222,"username":"ops"}]
        """
        let hops = try JSONDecoder().decode([SSHJumpHost].self, from: Data(json.utf8))

        #expect(hops.count == 1)
        #expect(hops[0].host == "bastion.example.com")
        #expect(hops[0].port == 2_222)
        #expect(hops[0].authMethod == .sshAgent)
        #expect(hops[0].privateKeyPath == "")
    }

    @Test("A hop with no id and no port still decodes")
    func testDecodesHopWithoutIdOrPort() throws {
        let json = #"[{"host":"bastion.example.com","username":"ops"}]"#
        let hops = try JSONDecoder().decode([SSHJumpHost].self, from: Data(json.utf8))

        #expect(hops.count == 1)
        #expect(hops[0].port == nil)
        #expect(hops[0].username == "ops")
    }

    @Test("An auth method this app does not know falls back to SSH Agent")
    func testDecodesUnknownAuthMethod() throws {
        let json = #"[{"host":"bastion.example.com","username":"ops","authMethod":"totp-only"}]"#
        let hops = try JSONDecoder().decode([SSHJumpHost].self, from: Data(json.utf8))

        #expect(hops[0].authMethod == .sshAgent)
    }

    @Test("A hop an iPhone wrote by case name keeps the method it names")
    func testDecodesIOSSpelling() throws {
        let json = """
        [{"host":"b1.example.com","username":"ops","authMethod":"sshAgent"},
         {"host":"b2.example.com","username":"ops","authMethod":"privateKey","privateKeyPath":"~/.ssh/id"}]
        """
        let hops = try JSONDecoder().decode([SSHJumpHost].self, from: Data(json.utf8))

        #expect(hops[0].authMethod == .sshAgent)
        #expect(hops[1].authMethod == .privateKey)
    }

    @Test("A hop with no port encodes without the key, so the config lookup still applies")
    func testEncodesNoPortAsAbsentKey() throws {
        let data = try JSONEncoder().encode(SSHJumpHost(host: "bastion.example.com", username: "ops"))
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(fields["port"] == nil)
        #expect(fields["authMethod"] as? String == "SSH Agent")
    }
}
