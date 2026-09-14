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

    @Test("A configuration this model creates omits the macOS-only keys, so the host inference is unchanged")
    func iosCreatedConfigOmitsMacKeys() throws {
        let config = SSHConfiguration(host: "prod-1", username: "deploy")
        let reencoded = try JSONEncoder().encode(config)
        let fields = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        #expect(fields["enabled"] == nil)
        #expect(fields["remoteFilePath"] == nil)
        #expect(fields["agentSocketPath"] == nil)
    }
}
