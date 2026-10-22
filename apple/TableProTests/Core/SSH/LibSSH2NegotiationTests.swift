import Foundation
import Testing

import CLibSSH2
import TableProSSHTransport

@testable import TablePro

// The server side is written ahead into a socket pair: a banner, then a KEXINIT, a DISCONNECT or
// nothing. The method names it offers are made up, so no libssh2 build can agree on them.
struct LibSSH2NegotiationTests {
    private static let endpoint = ConnectionTimeoutEndpoint.tunnel("ssh.example:22")
    private static let banner = Data("SSH-2.0-OpenSSH_10.3\r\n".utf8)

    @Test("No common key exchange names that stage, the server software and TablePro's methods")
    func keyExchangeFailure() throws {
        let failure = try negotiationFailure(offering: ServerKexInit(kex: "unknown-kex@example.com"))

        #expect(failure.stage == .keyExchangeOrHostKey)
        #expect(failure.serverSoftware == "OpenSSH_10.3")
        #expect(failure.supported.contains("curve25519-sha256"))
        #expect(!failure.supported.contains("ext-info-c"))
        #expect(failure.supportedHostKeys.contains("ssh-ed25519"))
    }

    @Test("An agreed key exchange with no common cipher names the cipher stage")
    func cipherFailure() throws {
        let failure = try negotiationFailure(offering: ServerKexInit(cipher: "unknown-cipher@example.com"))

        #expect(failure.stage == .cipher)
        #expect(failure.supported.contains("aes256-ctr"))
        #expect(failure.supportedHostKeys.isEmpty)
    }

    @Test("An agreed cipher that needs a MAC with no common MAC names the MAC stage")
    func macFailure() throws {
        let failure = try negotiationFailure(offering: ServerKexInit(mac: "unknown-mac@example.com"))

        #expect(failure.stage == .mac)
        #expect(failure.supported.contains("hmac-sha2-256"))
    }

    @Test("A server that hangs up after its banner is not a negotiation failure")
    func hangUpAfterBannerIsNotANegotiation() throws {
        let error = try handshakeError(serverWrites: Self.banner, thenHangsUp: true)

        #expect(error == .tunnelCreationFailed(
            "SSH handshake failed: The SSH server closed the connection during the handshake."
        ))
    }

    @Test("A server that disconnects after its banner is named with its own reason, not as a negotiation failure")
    func disconnectAfterBannerIsNotANegotiation() throws {
        var written = Self.banner
        written.append(SSHPacket.disconnect(reason: 12, description: "Too many connections\r\n"))

        let error = try handshakeError(serverWrites: written, thenHangsUp: false)

        #expect(error == .tunnelCreationFailed(
            "SSH handshake failed: The SSH server ended the connection during the handshake: Too many connections"
        ))
    }

    @Test("A handshake that fails before negotiation keeps libssh2's text")
    func bannerFailureIsNotANegotiation() throws {
        let error = try handshakeError(serverWrites: Data("HTTP/1.1 400 Bad Request\r\n".utf8), thenHangsUp: true)

        guard case .tunnelCreationFailed(let message) = error else {
            Issue.record("expected tunnelCreationFailed, got \(error)")
            return
        }
        #expect(message.hasPrefix("SSH handshake failed: "))
        #expect(!message.contains("closed the connection during the handshake"))
    }

    private func negotiationFailure(offering kexInit: ServerKexInit) throws -> SSHNegotiationFailure {
        var written = Self.banner
        written.append(kexInit.packet)
        let error = try handshakeError(serverWrites: written, thenHangsUp: false)
        guard case .negotiationFailed(let failure, let jumpHost) = error else {
            Issue.record("expected negotiationFailed, got \(error)")
            throw error
        }
        #expect(jumpHost == nil)
        return failure
    }

    // What the server says fits the socket buffer, so it is written before the client starts. A
    // hang-up closes only the server's sending side, so the client's own writes still land.
    private func handshakeError(serverWrites data: Data, thenHangsUp: Bool) throws -> SSHTunnelError {
        _ = LibSSH2TunnelFactory.initialized
        let pair = SocketPair()
        defer { pair.close() }
        try #require(pair.a >= 0)

        let sent = data.withUnsafeBytes { Darwin.write(pair.b, $0.baseAddress, $0.count) }
        try #require(sent == data.count)
        if thenHangsUp {
            shutdown(pair.b, SHUT_WR)
        }

        let deadline = ConnectionDeadline(configuredSeconds: 10)
        let attempt = SSHConnectionAttempt(deadline: deadline, endpoint: Self.endpoint)
        return try #require(throws: SSHTunnelError.self) {
            let session = try LibSSH2TunnelFactory.createSession(
                socketFD: pair.a,
                endpoint: Self.endpoint,
                deadline: deadline,
                attempt: attempt
            )
            libssh2_session_free(session)
        }
    }
}

// RFC 4253, 6: sent before any keys exist, so no MAC, and padding to a multiple of 8.
private enum SSHPacket {
    static func frame(_ payload: Data) -> Data {
        var padding = 8 - (5 + payload.count) % 8
        if padding < 4 { padding += 8 }
        var packet = uint32(UInt32(1 + payload.count + padding))
        packet.append(UInt8(padding))
        packet.append(payload)
        packet.append(Data(repeating: 0, count: padding))
        return packet
    }

    // RFC 4253, 11.1.
    static func disconnect(reason: UInt32, description: String) -> Data {
        var payload = Data([1])
        payload.append(uint32(reason))
        payload.append(string(description))
        payload.append(string(""))
        return frame(payload)
    }

    static func string(_ value: String) -> Data {
        var data = uint32(UInt32(value.utf8.count))
        data.append(Data(value.utf8))
        return data
    }

    static func uint32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}

// RFC 4253, 7.1.
private struct ServerKexInit {
    var kex = "curve25519-sha256"
    var hostKey = "ssh-ed25519"
    var cipher = "aes128-ctr"
    var mac = "hmac-sha2-256"

    var packet: Data {
        var payload = Data([20])
        payload.append(Data(repeating: 0x5A, count: 16))
        for list in [kex, hostKey, cipher, cipher, mac, mac, "none", "none", "", ""] {
            payload.append(SSHPacket.string(list))
        }
        payload.append(0)
        payload.append(contentsOf: [0, 0, 0, 0])
        return SSHPacket.frame(payload)
    }
}
