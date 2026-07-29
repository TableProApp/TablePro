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
}
