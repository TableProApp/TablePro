import Foundation
import Testing

@testable import TableProModels

@Suite("iOS SSHConfiguration auth method decoding")
struct SSHConfigurationTests {
    private func decode(authMethod raw: String) throws -> SSHConfiguration {
        let json = """
        {"host":"ssh.example.com","port":22,"username":"tailscale","authMethod":"\(raw)","jumpHosts":[]}
        """
        return try JSONDecoder().decode(SSHConfiguration.self, from: Data(json.utf8))
    }

    @Test("decodes the macOS None raw value")
    func decodesMacOSNone() throws {
        #expect(try decode(authMethod: "None").authMethod == .none)
    }

    @Test("decodes the lowercase none raw value")
    func decodesLowercaseNone() throws {
        #expect(try decode(authMethod: "none").authMethod == .none)
    }

    @Test("None survives an encode and decode round trip")
    func roundTripsNone() throws {
        let config = SSHConfiguration(host: "ssh.example.com", username: "tailscale", authMethod: .none)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SSHConfiguration.self, from: data)
        #expect(decoded.authMethod == .none)
    }

    @Test("an unrecognized auth method still falls back to password")
    func unknownFallsBackToPassword() throws {
        #expect(try decode(authMethod: "totp-only").authMethod == .password)
    }

    // MARK: - Sync round trip preserves the macOS fields

    private func reencodedFields(_ macJSON: String) throws -> [String: Any] {
        let decoded = try JSONDecoder().decode(SSHConfiguration.self, from: Data(macJSON.utf8))
        let reencoded = try JSONEncoder().encode(decoded)
        return try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
    }

    @Test("The macOS SSH enabled flag, remote file path and access mode survive an iOS round trip")
    func preservesMacRemoteFileFields() throws {
        let macJSON = """
        {"enabled":true,"host":"prod-1","port":22,"username":"deploy","authMethod":"password",
         "jumpHosts":[],"agentSocketPath":"/tmp/agent.sock","remoteFilePath":"/srv/app.db",
         "remoteFileAccess":"onServer","totpMode":"totp","totpDigits":6}
        """
        let fields = try reencodedFields(macJSON)
        #expect(fields["enabled"] as? Bool == true)
        #expect(fields["remoteFilePath"] as? String == "/srv/app.db")
        #expect(fields["remoteFileAccess"] as? String == "onServer")
        #expect(fields["agentSocketPath"] as? String == "/tmp/agent.sock")
        #expect(fields["totpMode"] as? String == "totp")
    }

    @Test("A configuration never encodes a private key field")
    func neverEncodesPrivateKey() throws {
        let config = SSHConfiguration(
            host: "prod-1",
            username: "deploy",
            authMethod: .privateKey,
            privateKeyPath: "/keys/id_ed25519"
        )
        let fields = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
        )
        #expect(fields["privateKeyData"] == nil)
        #expect(fields["privateKeyPath"] as? String == "/keys/id_ed25519")
    }

    @Test("JSON an older build wrote with a pasted key still decodes, and re-encodes without the key")
    func legacyPastedKeyIsDropped() throws {
        let keyText = "-----BEGIN OPENSSH PRIVATE KEY-----\\nb3BlbnNzaC1rZXktdjE\\n-----END OPENSSH PRIVATE KEY-----"
        let legacyJSON = """
        {"host":"prod-1","port":2222,"username":"deploy","authMethod":"privateKey",
         "privateKeyData":"\(keyText)","jumpHosts":[]}
        """
        let decoded = try JSONDecoder().decode(SSHConfiguration.self, from: Data(legacyJSON.utf8))
        #expect(decoded.host == "prod-1")
        #expect(decoded.port == 2_222)
        #expect(decoded.authMethod == .privateKey)

        let reencoded = try JSONEncoder().encode(decoded)
        let text = try #require(String(data: reencoded, encoding: .utf8))
        #expect(!text.contains("privateKeyData"))
        #expect(!text.contains("b3BlbnNzaC1rZXktdjE"))
    }

    @Test("A configuration this model creates omits the macOS-only keys, so the host inference is unchanged")
    func iosCreatedConfigOmitsMacKeys() throws {
        let config = SSHConfiguration(host: "prod-1", username: "deploy")
        let reencoded = try JSONEncoder().encode(config)
        let fields = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        #expect(fields["enabled"] == nil)
        #expect(fields["remoteFilePath"] == nil)
        #expect(fields["agentSocketPath"] == nil)
    }

    // MARK: - Jump hosts

    private static let macJumpHostsJSON = """
    {"host":"db-1","port":22,"username":"deploy","authMethod":"password","jumpHosts":[
      {"id":"6E0B1B3C-7E4C-4C3E-9B1E-4C8D2A1F0001","host":"bastion-1","username":"ops",
       "authMethod":"SSH Agent","privateKeyPath":""},
      {"id":"6E0B1B3C-7E4C-4C3E-9B1E-4C8D2A1F0002","host":"bastion-2","port":2222,"username":"ops",
       "authMethod":"Private Key","privateKeyPath":"~/.ssh/id_ed25519"}
    ]}
    """

    @Test("A hop the Mac wrote without a port decodes instead of dropping every hop")
    func portlessHopDecodes() throws {
        let config = try JSONDecoder().decode(SSHConfiguration.self, from: Data(Self.macJumpHostsJSON.utf8))

        #expect(config.jumpHosts.count == 2)
        #expect(config.jumpHosts[0].host == "bastion-1")
        #expect(config.jumpHosts[0].port == nil)
        #expect(config.jumpHosts[1].port == 2_222)
    }

    @Test("A hop's auth method and key path survive an iOS round trip")
    func preservesJumpHostCredentialFields() throws {
        let decoded = try JSONDecoder().decode(SSHConfiguration.self, from: Data(Self.macJumpHostsJSON.utf8))
        #expect(decoded.jumpHosts[0].macAuthMethod == "SSH Agent")
        #expect(decoded.jumpHosts[1].macAuthMethod == "Private Key")
        #expect(decoded.jumpHosts[1].macPrivateKeyPath == "~/.ssh/id_ed25519")

        let reencoded = try JSONEncoder().encode(decoded)
        let fields = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        let hops = try #require(fields["jumpHosts"] as? [[String: Any]])

        #expect(hops.count == 2)
        #expect(hops[0]["authMethod"] as? String == "SSH Agent")
        #expect(hops[0]["privateKeyPath"] as? String == "")
        #expect(hops[0]["port"] == nil)
        #expect(hops[0]["id"] as? String == "6E0B1B3C-7E4C-4C3E-9B1E-4C8D2A1F0001")
        #expect(hops[1]["authMethod"] as? String == "Private Key")
        #expect(hops[1]["privateKeyPath"] as? String == "~/.ssh/id_ed25519")
        #expect(hops[1]["port"] as? Int == 2_222)
    }

    @Test("A hop this model creates still carries the keys the macOS decode requires")
    func iosCreatedHopCarriesMacKeys() throws {
        let config = SSHConfiguration(host: "db-1", jumpHosts: [SSHJumpHost(host: "bastion-1")])
        let fields = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
        )
        let hops = try #require(fields["jumpHosts"] as? [[String: Any]])

        #expect(hops[0]["authMethod"] as? String == "SSH Agent")
        #expect(hops[0]["privateKeyPath"] as? String == "")
        #expect(hops[0]["port"] == nil)
    }

    @Test("A hop a shipped iOS build wrote without credentials still decodes")
    func legacyIOSHopDecodes() throws {
        let legacy = """
        {"host":"db-1","port":22,"username":"deploy","authMethod":"password","jumpHosts":[
          {"id":"6E0B1B3C-7E4C-4C3E-9B1E-4C8D2A1F0003","host":"bastion-1","port":22,"username":"ops"}
        ]}
        """
        let config = try JSONDecoder().decode(SSHConfiguration.self, from: Data(legacy.utf8))

        #expect(config.jumpHosts.count == 1)
        #expect(config.jumpHosts[0].port == 22)
        #expect(config.jumpHosts[0].macAuthMethod == "SSH Agent")
        #expect(config.jumpHosts[0].macPrivateKeyPath == "")
    }
}
