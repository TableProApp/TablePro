import Foundation
import Testing

@testable import TableProSSHTransport

struct SSHServerProposalTests {
    static let banner = Array("SSH-2.0-OpenSSH_7.4\r\n".utf8)

    @Test("The server's KEXINIT after its identification line gives each name-list")
    func readsTheKexInit() throws {
        let proposal = try #require(SSHServerProposal(received: Self.banner + Self.kexInit()))

        #expect(proposal.keyExchange == ["diffie-hellman-group14-sha1", "ext-info-s"])
        #expect(proposal.hostKeys == ["ssh-rsa"])
        #expect(proposal.ciphersClientToServer == ["aes128-ctr", "3des-cbc"])
        #expect(proposal.ciphersServerToClient == ["aes256-ctr"])
        #expect(proposal.macsClientToServer == ["hmac-sha1"])
        #expect(proposal.macsServerToClient == ["hmac-md5"])
    }

    @Test("Lines before the identification line and an IGNORE before the KEXINIT are skipped")
    func skipsWhatComesFirst() throws {
        let received = Array("Authorized use only\r\nSSH-2.0-OpenSSH_7.4\r\n".utf8)
            + Self.packet([2] + Self.string("padding the server sends first"))
            + Self.kexInit()

        let proposal = try #require(SSHServerProposal(received: received))

        #expect(proposal.hostKeys == ["ssh-rsa"])
    }

    @Test(
        "Anything short of a whole KEXINIT reads as nothing",
        arguments: [
            [],
            SSHServerProposalTests.banner,
            SSHServerProposalTests.kexInit(),
            Array((SSHServerProposalTests.banner + SSHServerProposalTests.kexInit()).dropLast(12)),
            SSHServerProposalTests.banner + SSHServerProposalTests.packet([1, 0, 0, 0, 2]),
        ]
    )
    func incompleteReadsAsNothing(received: [UInt8]) {
        #expect(SSHServerProposal(received: received) == nil)
    }

    // RFC 4253, 7.1.
    static func kexInit() -> [UInt8] {
        var payload: [UInt8] = [20] + [UInt8](repeating: 0x5A, count: 16)
        for list in [
            "diffie-hellman-group14-sha1,ext-info-s", "ssh-rsa", "aes128-ctr,3des-cbc", "aes256-ctr",
            "hmac-sha1", "hmac-md5", "none", "none", "", "",
        ] {
            payload += string(list)
        }
        payload += [0, 0, 0, 0, 0]
        return packet(payload)
    }

    // RFC 4253, 6: no MAC before the first NEWKEYS.
    static func packet(_ payload: [UInt8]) -> [UInt8] {
        var padding = 8 - (5 + payload.count) % 8
        if padding < 4 { padding += 8 }
        return uint32(UInt32(1 + payload.count + padding)) + [UInt8(padding)] + payload
            + [UInt8](repeating: 0, count: padding)
    }

    private static func string(_ value: String) -> [UInt8] {
        uint32(UInt32(value.utf8.count)) + Array(value.utf8)
    }

    private static func uint32(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }
}
