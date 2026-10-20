//
//  SSHPrivateKeyTraitsTests.swift
//  TableProSSHTransportTests
//

import Foundation
import Testing

@testable import TableProSSHTransport

struct SSHPrivateKeyTraitsTests {
    @Test("A plain key reads its type and is not encrypted", arguments: ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256"])
    func plainKey(keyType: String) throws {
        let traits = try #require(SSHPrivateKeyTraits(openSSH: OpenSSHKeyFile.armored(cipher: "none", keyType: keyType)))

        #expect(traits.keyType == keyType)
        #expect(!traits.isEncrypted)
        #expect(!traits.isSecurityKey)
    }

    @Test("An encrypted key still reads its type", arguments: ["aes256-ctr", "aes256-gcm@openssh.com", "chacha20-poly1305@openssh.com"])
    func encryptedKey(cipher: String) throws {
        let traits = try #require(SSHPrivateKeyTraits(openSSH: OpenSSHKeyFile.armored(cipher: cipher, keyType: "ssh-ed25519")))

        #expect(traits.keyType == "ssh-ed25519")
        #expect(traits.isEncrypted)
    }

    @Test("A FIDO key is a security key", arguments: ["sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com"])
    func securityKey(keyType: String) throws {
        let traits = try #require(SSHPrivateKeyTraits(openSSH: OpenSSHKeyFile.armored(cipher: "none", keyType: keyType)))

        #expect(traits.isSecurityKey)
        #expect(traits.keyType == keyType)
    }

    @Test("CRLF line endings and text around the block still parse")
    func toleratesLayout() throws {
        let armored = OpenSSHKeyFile.armored(cipher: "aes256-ctr", keyType: "ssh-rsa")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let traits = try #require(SSHPrivateKeyTraits(openSSH: "  \nComment above\n" + armored + "\n\n"))

        #expect(traits.keyType == "ssh-rsa")
        #expect(traits.isEncrypted)
    }

    @Test("A key whose public section is cut short keeps its cipher but has no type")
    func truncatedAfterCipher() throws {
        let cut = Array(OpenSSHKeyFile.container(cipher: "aes256-ctr", keyType: "ssh-ed25519").prefix(40))
        let traits = try #require(SSHPrivateKeyTraits(openSSH: OpenSSHKeyFile.armor(cut)))

        #expect(traits.isEncrypted)
        #expect(traits.keyType == nil)
        #expect(!traits.isSecurityKey)
    }

    @Test("A container that lists no keys has no type")
    func noKeys() throws {
        let empty = OpenSSHKeyFile.container(cipher: "none", keyType: "ssh-ed25519", keyCount: 0)
        let traits = try #require(SSHPrivateKeyTraits(openSSH: OpenSSHKeyFile.armor(empty)))

        #expect(traits.keyType == nil)
    }

    @Test("A length past the end of the data is not read")
    func oversizedLength() throws {
        var bytes = OpenSSHKeyFile.magic
        bytes += OpenSSHKeyFile.uint32(10)
        bytes += Array("none".utf8)

        #expect(SSHPrivateKeyTraits(openSSH: OpenSSHKeyFile.armor(bytes)) == nil)
    }

    @Test(
        "Text that is not an openssh-key-v1 key gives no traits",
        arguments: [
            "",
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA user@host",
            "-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJBAK\n-----END RSA PRIVATE KEY-----\n",
            "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjE\n",
            "-----BEGIN OPENSSH PRIVATE KEY-----\n!!!not base64!!!\n-----END OPENSSH PRIVATE KEY-----\n",
        ]
    )
    func notAnOpenSSHKey(text: String) {
        #expect(SSHPrivateKeyTraits(openSSH: text) == nil)
    }

    @Test("A body without the openssh-key-v1 magic gives no traits")
    func wrongMagic() {
        let bytes = Array("openssh-key-v2\0".utf8) + OpenSSHKeyFile.field(Array("none".utf8))

        #expect(SSHPrivateKeyTraits(openSSH: OpenSSHKeyFile.armor(bytes)) == nil)
    }

    @Test("An empty cipher name gives no traits")
    func emptyCipher() {
        let bytes = OpenSSHKeyFile.magic + OpenSSHKeyFile.field([])

        #expect(SSHPrivateKeyTraits(openSSH: OpenSSHKeyFile.armor(bytes)) == nil)
    }
}

private enum OpenSSHKeyFile {
    static let magic = Array("openssh-key-v1\0".utf8)

    static func armored(cipher: String, keyType: String) -> String {
        armor(container(cipher: cipher, keyType: keyType))
    }

    static func container(cipher: String, keyType: String, keyCount: UInt32 = 1) -> [UInt8] {
        let encrypted = cipher != "none"
        let kdfOptions = encrypted ? field([UInt8](repeating: 7, count: 16)) + uint32(16) : []
        let publicKey = field(Array(keyType.utf8)) + field([UInt8](repeating: 1, count: 32))
        var bytes = magic
        bytes += field(Array(cipher.utf8))
        bytes += field(Array((encrypted ? "bcrypt" : "none").utf8))
        bytes += field(kdfOptions)
        bytes += uint32(keyCount)
        bytes += field(publicKey)
        bytes += field([UInt8](repeating: 9, count: 64))
        return bytes
    }

    static func armor(_ bytes: [UInt8]) -> String {
        let body = Data(bytes).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(body)\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    static func field(_ bytes: [UInt8]) -> [UInt8] {
        uint32(UInt32(bytes.count)) + bytes
    }

    static func uint32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
